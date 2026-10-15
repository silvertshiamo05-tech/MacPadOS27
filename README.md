# MacPadOS27

Run your own Unity IL2CPP **macOS** games on an iPad (A14+, LiveContainer)
without rebuilding them. A small loader app plus the game files you copy in.

Status: **step 1, inspecting the game.** See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the plan and the feasibility assessment.

Everything here is driven from a phone browser. No PC or Mac is needed: builds
run on GitHub Actions.

> Never commit game files to this repo. Inspector reports hold only names and
> version numbers.

## Step 1: inspect your game (Android phone)

You need the game's macOS `.app` (for example `Sinisistar 2.app`) on your phone,
as a `.zip` or as a folder.

1. Open the Build Inspector page in Chrome. It runs entirely on the phone and
   uploads nothing. Use the hosted link from the project chat, or open
   `web/inspector.html` in this repo.
2. Tap **Choose .zip** and pick the zipped `.app`. You can also tap
   **Choose files** and pick these files from inside `Game.app/Contents/`:
   - `Frameworks/GameAssembly.dylib`
   - `Resources/Data/il2cpp_data/Metadata/global-metadata.dat`
   - `Resources/Data/globalgamemanagers`
   - `Info.plist`
3. Read the summary: Unity version, IL2CPP or Mono, whether GameAssembly has
   an **arm64** slice, and any blockers.
4. Tap **Copy report**. In this repo on github.com, tap **Add file → Create new
   file**, name it `reports/sinisistar2.json`, paste, and tap **Commit**.
5. Open the **Actions** tab. The **ios-symbol-check** run links every function
   GameAssembly imports against the real iPadOS SDK and lists anything the
   iPad is missing (open the run, then its Summary).

### Same check from Termux (optional)

```sh
pkg install python git
git clone https://github.com/silvertshiamo05-tech/MacPadOS27
python MacPadOS27/tools/unity_inspect.py "/sdcard/Download/Sinisistar 2.app.zip" --json report.json
```

## Layout

| Path | What |
|---|---|
| `web/inspector.html` | Phone inspector (single file, no upload) |
| `tools/unity_inspect.py` | The same inspector for Termux and CI |
| `ci/ios_symbol_check.py` | Links GameAssembly's imports against the iPadOS SDK (macOS runner) |
| `.github/workflows/ios-symbol-check.yml` | Runs the symbol check when a report lands in `reports/` |
| `.github/workflows/tests.yml` | Unit tests; checks the web and Python inspectors agree |
| `docs/ARCHITECTURE.md` | Design, risks and phases |
