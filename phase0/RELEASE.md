MacPadOS27 test build. Contains only the MacPadOS27 test project, no game files.

**Install (iPad, Safari):** tap `MacPadOS27.ipa` → Download → LiveContainer → **+** → pick it from Files → Downloads.

**1. Demo (no JIT):** just launch MacPadOS27. It runs the built-in macOS test game through the loader.
Expected: spinning cube + orange/blue checkerboard, 2nd line `data built for StandaloneOSX`.

**2. A game from Files (JIT):** copy a macOS `Game.app` (e.g. `Phase0Test.app` from `Phase0Test-mac.zip`, later
`SiNiSistar2.app`) into Files → On My iPad → LiveContainer → Data → Application → (MacPadOS27's folder) → Documents → **Game**,
then launch MacPadOS27 with JIT. The first launch prepares the game's data (converts textures), which can take a while.

**Logs** (same Documents folder): `mp27-loader.log` and `unity-player.log`. Send both after any problem.
