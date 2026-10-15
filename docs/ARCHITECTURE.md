# MacPadOS27: architecture and feasibility

Goal: a small iPadOS app (sideloaded through LiveContainer) that runs the
**user's own** Unity IL2CPP macOS game files, copied in through the Files app,
without rebuilding the game. First target: Sinisistar 2. Device: iPad 10th gen
(A14, arm64, Apple7 GPU family, 4 GB RAM, iPadOS 16.1+).

## Short verdict

Feasible as a research project, with no guarantee. The engine and IL2CPP
plumbing has a clear path. One large unknown can only be settled by
experiment: will the iOS Unity player load scene and asset data that was built
for `StandaloneOSX`? Phase 0 below answers that cheaply, using a tiny test
game we build ourselves, before any work goes into Sinisistar 2.

## How the two builds differ

| Piece | macOS IL2CPP build | iOS IL2CPP build |
|---|---|---|
| Engine | `Contents/Frameworks/UnityPlayer.dylib` (AppKit, IOKit HID, CoreAudio HAL, Metal) | `UnityFramework.framework` built from `libiPhone-lib.a` (UIKit, Metal) |
| IL2CPP runtime + game code | `Contents/Frameworks/GameAssembly.dylib`, a separate dylib. UnityPlayer `dlopen`s it and resolves `il2cpp_*` with `dlsym` | Compiled from generated C++ and **statically linked** into UnityFramework |
| Metadata | `Contents/Resources/Data/il2cpp_data/Metadata/global-metadata.dat` | `Data/Managed/Metadata/global-metadata.dat` |
| Scenes and assets | `Contents/Resources/Data/*` | `Data/*` inside the app bundle |
| StreamingAssets | `Contents/Resources/Data/StreamingAssets` | `Data/Raw` |
| Graphics API | Metal | Metal |

On the Mac, the engine and the game code already meet at a **dynamic**
boundary: `GameAssembly.dylib` exports the `il2cpp_*` C API, and UnityPlayer
calls into it. That boundary is what this project uses.

## Recommended architecture: iOS Unity player + the game's GameAssembly

```
 MacPadOS27.app (our IPA, built in CI)
 ├─ UnityFramework  ← iOS engine of the SAME Unity version as the game
 │    └─ il2cpp forwarder (ours, replaces the static libil2cpp/game code)
 │          il2cpp_init(...) ─────┐  each il2cpp_* API call is forwarded
 │          il2cpp_class_from_name ┤  through a function pointer that is
 │          ... (~250 functions)   ┘  filled with dlsym() at startup
 ├─ loader (ours): pick game folder, patch + load GameAssembly, remap paths,
 │                 icall shims, input overlay
 └─ Info.plist: UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace

 Documents/Games/<Game>/            (copied by the user from the Mac .app)
 ├─ GameAssembly.dylib   → LC_BUILD_VERSION patched macOS→iOS, re-signed/JIT
 ├─ Data/ (Contents/Resources/Data)  → used as the player's data folder
 └─ global-metadata.dat path remapped through il2cpp_set_data_dir
```

### Why this one

* The iOS engine is a real UIKit/Metal player, so there is no AppKit shim to
  write for the engine itself.
* The game's own compiled code runs unmodified. IL2CPP is ahead-of-time
  compiled native arm64, so **no JIT is needed to execute it**.
* Everything game-specific is data plus one dylib, so the same IPA build
  pipeline works for any Unity IL2CPP game of the same Unity version.

### The engine ↔ GameAssembly contract (why the version must match exactly)

1. **The `il2cpp_*` C API.** About 200 to 260 functions, generated from
   `il2cpp-api-functions.h`, which ships with each editor. The list is the
   same on macOS and iOS for one Unity version, because both use the same
   libil2cpp source. The forwarder is generated from that header for each
   version.
2. **Internal calls (icalls).** The engine registers native functions by
   name (`UnityEngine.Transform::get_position_Injected`, ...) with
   `il2cpp_add_internal_call`. Managed code resolves them by name the first
   time each one is called. Their names and signatures change between Unity
   versions. A few exist only on macOS: those fail when first called, not at
   startup, and we can register stubs for them.
3. **Shared memory layouts.** The engine and managed code both touch
   `UnityEngine.Object.m_CachedPtr`, structs passed by value, and array and
   string layouts. These are identical only within one Unity version.

So the shell must be built with **exactly** the game's Unity version, down to
the `fN` suffix. Step 1 reads that version from the game's data files.

### Static UnityFramework vs dynamic loading

On iOS, `libiPhone-lib.a` (the engine) expects the IL2CPP runtime to be linked
statically. In the generated Xcode project, the blank shell's own
`Il2CppOutputProject` is replaced by our **forwarder**: a static library that
defines every `il2cpp_*` symbol as a trampoline into the user's
`GameAssembly.dylib`. The forwarder also lets us intercept specific calls:

* `il2cpp_set_data_dir`: point it at `<game>/Data/il2cpp_data`, the Mac path.
* `il2cpp_init`: load the dylib first, then register icall shims after init.

**Risk to check in Phase 0:** whether `libiPhone-lib.a` references libil2cpp
symbols *beyond* the public `il2cpp_*` API (internal C++ symbols are
reachable in a static link). A CI step will run `nm -u` on the engine library
and list anything the forwarder cannot supply. If that list is not empty,
those internals have to be located inside GameAssembly.dylib by signature.
That is harder, but still bounded work.

The engine classes the shell registers come from Unity's build-time stripping.
The shell is built with **Strip Engine Code off** and every built-in module
enabled, so no class or icall the game needs is missing.

### Code signing, JIT and LiveContainer

* dyld will not load a binary whose platform is macOS into an iOS process
  ("incompatible platform"). The loader therefore patches `LC_BUILD_VERSION`
  (platform 1 → 2, minos → 15.0) in the arm64 slice, the zorrobyte technique.
  This is a few bytes and can run on the iPad when the game is imported, so no
  PC is needed.
* Patching invalidates the dylib's Apple signature. Two ways to load it:
  1. **JIT enabled via StikDebug.** The process becomes `CS_DEBUGGED`, and
     LiveContainer can then map code that is not validly signed. You already
     have this set up, so it is the first path we test.
  2. **JIT-less.** LiveContainer signs code inside a guest app's bundle with
     its own certificate. The loader copies the patched dylib into its bundle's
     `Frameworks/` and has LiveContainer re-sign it. This is more convenient
     day to day; exactly how to trigger the re-sign needs investigating.
* Unity builds plain `arm64`, not `arm64e`, so pointer authentication is not
  an issue.

### Graphics: Metal on both sides

* Modern Unity Mac builds use Metal (OpenGLCore has been deprecated since
  2019), and iOS is Metal-only. Unity's "Metal" shader platform is shared by
  macOS and iOS. Shaders ship as MSL source and are compiled on the device, so
  Mac-built shaders are expected to compile on the A14. They were built with
  desktop defines (no `SHADER_API_MOBILE`), which matters little for a 2D game.
* **Texture formats.** Mac builds use BC/DXT compression. The A14 is not
  expected to report `supportsBCTextureCompression`, which M1 iPads do; the
  shell logs the real value at startup. If BC is missing, Unity falls back to
  decompressing on the CPU, which costs memory and load time. Pixel-art games
  often ship uncompressed textures anyway.
* No OpenGL translation (ANGLE, MoltenGL) is involved. A game built
  OpenGL-only (Unity 5.x era) is out of scope.

### Data compatibility (the biggest unknown)

Every serialized file records the build target (`StandaloneOSX` = 2; step 1
prints it). Player builds have no type trees, so the iOS player reads
objects using its own compiled-in layout for that Unity version. Most classes
serialize identically on both platforms. Some may not: platform-specific
texture data, quality settings, and the input manager are the ones to watch.

* If the iOS player accepts the data: no conversion needed.
* If it rejects it because of the target check alone: patch the target field in
  the loaded headers (cheap).
* If layouts genuinely differ: per-class conversion (AssetRipper-style). That
  is expensive, and the project would need rethinking.

AssetBundles and Addressables check the target platform strictly. That check
would need patching or hooking.

### macOS-only calls and shims

| Layer | What breaks | Fix |
|---|---|---|
| GameAssembly imports | libSystem/Foundation symbols missing on iOS; Mac-only frameworks | `ios-symbol-check` CI lists them exactly; shim dylibs with matching install names |
| icalls | Mac-only engine APIs (cursor, window, display modes) | stub icalls registered after `il2cpp_init` |
| Native plugins | `.bundle` plugins (Steamworks, FMOD, ...) are Mac binaries | iOS build of the same SDK, a re-targeted copy, or a "not available" stub |
| Paths | `persistentDataPath`, StreamingAssets location | path remap in the shell; saves live under the game folder |

Steam: if the game exits when Steam is not running, that is DRM. This project
will not fake Steam ownership. Stubs only ever report "Steam not available",
which works for games that treat Steam as optional.

### Input

* **Physical controllers** (Xbox, PlayStation, MFi) reach Unity on iOS through
  GameController.framework with no extra work.
* **Touch:** `GCVirtualController` (iOS 15+) draws an on-screen gamepad that
  the system presents as a real `GCController`. A game with gamepad support
  needs no further mapping.
* **Keyboard-only games:** override the `UnityEngine.Input::GetKey*` icalls
  so virtual buttons also count as key presses. This uses the same icall shim
  mechanism, so it works for any game.
* A hardware keyboard on the iPad works through Unity's iOS keyboard support.

### Files app under LiveContainer

`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` take effect
only when the IPA is installed on its own. Inside LiveContainer, guest apps
store data under LiveContainer's container, so the game folder appears in
Files at **On My iPad → LiveContainer → Data/Application/<uuid>/Documents**.
The loader will show that path on screen. The Info.plist keys are set anyway,
for direct installs (SideStore/AltStore).

### Fallback: the zorrobyte route (run the Mac player itself)

Patch `UnityPlayer.dylib` and the game binary to iOS and supply the missing
frameworks. UnityPlayer depends on AppKit (windows, events, menus), IOKit HID
(input), the CoreAudio HAL (FMOD output; most of the `AudioObject*` API is
absent on iOS) and macOS-only Metal storage modes. That amounts to a sizeable
AppKit, IOKit and CoreAudio emulation layer. Keep this only for Unity versions
where the main route fails.

## Phases

| Phase | Output | What it proves |
|---|---|---|
| **0. Proof with our own test game** | CI builds a tiny Unity project twice at one Unity version: a macOS IL2CPP arm64 build (the "test game") and the iOS shell with the forwarder. You install the IPA in LiveContainer, copy the test game in, and run it. | Mac data loads in the iOS player; the forwarder ABI; dylib patching and signing; the Files flow |
| **1. Inspect the real game** *(this commit)* | `unity_inspect` (web + Python) and `ios-symbol-check` CI | Exact Unity version, IL2CPP vs Mono, arm64 slice, imports, plugins |
| 2. Shell for the game's version | IPA artifact for Sinisistar 2's exact Unity version | Engine init with the real game |
| 3. Shims + input | icall stubs, plugin stubs, virtual controller | Playable |
| 4. Generalise | Version matrix: one shell IPA per Unity version | Other games |

### Costs and accounts you will need

* **Unity account (free, Personal license).** The Unity editor has to run in
  CI to produce the iOS player for a given version, and that needs an
  activated license stored in GitHub Secrets. This is the fiddliest setup
  step from a phone; Phase 0 docs will walk through it.
* **GitHub Actions minutes.** macOS runners are free on **public** repos.
  Private repos are billed at 10× (2,000 free minutes a month is about
  200 macOS minutes). A Unity install plus iOS build takes roughly 30–60
  minutes. A public repo is recommended. Game files never go in the repo;
  inspector reports contain only names and versions.
