Phase 0 test build. Contains only the MacPadOS27 test project, no game files.

**Install on the iPad (Safari):** tap an `.ipa` below → Download → in LiveContainer tap **+** and pick it from Files → Downloads. No JIT needed unless noted.

Every app now writes `unity-player.log` (Unity's console output and any crash) to its Documents folder:
Files → On My iPad → LiveContainer → Data → Application → (the app's folder) → Documents.

### Test in this order
| # | File | What it tests |
|---|---|---|
| 1 | `P0-1-platform.ipa` | All macOS data, with each file's "built for" field changed from macOS to iOS |
| 2 | `Phase0-loader-iosdata.ipa` | **The forwarder**: the macOS game code (GameAssembly.dylib) on the iOS engine, iOS data |
| 3 | `P0-2-managers.ipa` | Only the macOS project settings files (globalgamemanagers) |
| 4 | `P0-3-scene.ipa` | Only the macOS scene + its texture/material (level0, sharedassets0) |
| 5 | `P0-4-shaders.ipa` | Only the macOS built-in shaders (unity_builtin_extra) |
| 6 | `P0-5-resources.ipa` | Only the macOS resources.assets |
| – | `Phase0-native.ipa`, `Phase0-macdata.ipa`, `Phase0-loader.ipa` | Same as before, now with logs |

**Documents test (P0 Loader only, needs JIT):** put `Phase0Test.app` (from `Phase0Test-mac.zip`) into P0 Loader's
Documents → Game folder and launch P0 Loader **with JIT**. The 2nd line of `mp27-loader.log` must say `JIT (CS_DEBUGGED): YES`,
otherwise JIT did not attach and iPadOS will refuse the patched dylib (`code signature invalid`).

For each: **runs** (picture shows) or **crashes**. For every crash, send the end of its `unity-player.log`
(the last ~30 lines, screenshot is fine). For #2 also send `mp27-loader.log`.
