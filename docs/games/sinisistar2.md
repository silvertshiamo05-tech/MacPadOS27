# SiNiSistar2 (DLsite, macOS v1.3.1): step 1 results

Source: `reports/sinisistar2.json` (web inspector) and the `ios-symbol-check` run on iPhoneOS 18.5 SDK.

| Check | Result |
|---|---|
| Unity version | **2022.3.62f2**, changeset `7670c08855a9` (2022.3 LTS) |
| Scripting backend | IL2CPP |
| global-metadata.dat | standard header, version 31 |
| Data target | StandaloneOSX (serialized format 22) |
| GameAssembly.dylib | universal: x86_64 + **arm64** (macOS 11.0, SDK 15.5), not encrypted |
| il2cpp API exports | 241 |
| GameAssembly links | libSystem, libc++, CoreFoundation, Foundation, Security (no AppKit) |
| iPadOS symbol check | **all 342 imported symbols resolve** (libSystem 233, libc++ 98, CoreFoundation 11) |
| Native plugins | `steam_api.bundle` (x86_64 + arm64) |

## What this means

* No blockers. After the `LC_BUILD_VERSION` patch, dyld should load the arm64
  GameAssembly.dylib on iPadOS with nothing extra to shim.
* The iOS shell must be built with Unity **2022.3.62f2** exactly.
* Steam: the DLsite build still ships `steam_api`. P/Invoke loads it at runtime,
  so it is not in the import table. Whether the game needs it is checked in
  Phase 2. A "Steam not available" stub is the plan; Steam ownership will not
  be faked.
