Phase 0 test build. Contains only the MacPadOS27 test project, no game files.

**Install on the iPad (Safari):** tap an `.ipa` below → Download → in LiveContainer tap **+** and pick it from Files → Downloads.

| File | What it tests | Expected |
|---|---|---|
| `Phase0-native.ipa` | Control: the test project built normally for iOS | Spinning cube, orange/blue checker, report text |
| `Phase0-macdata.ipa` | iOS engine loading scene/asset files **built for macOS** | Same picture. The report's 2nd line must say `data built for StandaloneOSX` |
| `Phase0Test-mac.zip` | The macOS build of the test game (for run 2, the GameAssembly loader) | Keep it, not needed yet |

Run each app, then send back:
1. A screenshot, or what the screen shows.
2. If the app shows anything: `phase0.log` from Files → On My iPad → LiveContainer → Data → Application → (newest folder) → Documents.
3. If it crashes: say when (immediately, black screen, after a few seconds).
