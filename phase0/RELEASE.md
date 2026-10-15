Phase 0 test build. Contains only the MacPadOS27 test project, no game files.

**Install on the iPad (Safari):** tap an `.ipa` below → Download → in LiveContainer tap **+** and pick it from Files → Downloads.

| File | What it tests | Expected |
|---|---|---|
| `Phase0-native.ipa` | Control: the test project built normally for iOS | Spinning cube, orange/blue checker, report text |
| `Phase0-macdata.ipa` | iOS engine loading scene/asset files **built for macOS** | Same picture; 2nd line says `data built for StandaloneOSX` |
| `Phase0-loader.ipa` | The real loader: iOS engine running the **macOS GameAssembly.dylib** (bundled, pre-patched) + macOS data | Same picture; 2nd line says `data built for StandaloneOSX` |
| `Phase0Test-mac.zip` | The macOS build of the test game, for the Documents test below | |

**Documents test (loader only, needs JIT):** unzip `Phase0Test-mac.zip` in Files, then move `Phase0Test.app` into
Files → On My iPad → LiveContainer → Data → Application → (P0 Loader's folder) → Documents → **Game**
(the folder appears after the first launch). Launch P0 Loader with JIT enabled in StikDebug.

Send back for each app: a screenshot (or what the screen shows), and if it crashes, when.
Logs to send from that app's Documents folder: `phase0.log` and, for the loader, `mp27-loader.log`.
