# IstrolidR — local development launcher and reverse-engineering notes

**Status:** local Electron runtime bootstrapper, not a rewritten or open-source Istrolid game. It uses a locally installed official copy of [Istrolid on Steam](https://store.steampowered.com/app/449140/Istrolid/). No proprietary game code or assets are distributed by this repository.

## One-click Windows 10/11 run

1. Install the free original Istrolid through Steam.
2. Clone this repository: `git clone https://github.com/tndmadman/istrolidr.git`
3. Double-click **`Run-Istrolid.cmd`**. First run extracts the *local* official `resources/app.asar` into an isolated `.build/IstrolidR/resources/app` folder, copies the Electron runtime DLLs/executable, applies Git-tracked `overrides/`, then launches the resulting client. Subsequent runs are incremental.

No npm, C++ compiler, Visual Studio, or Python is needed; Windows PowerShell 5.1 is included with Windows 10.

If the installation isn't found, pass it explicitly:

```bat
Run-Istrolid.cmd -GameDir "D:\SteamLibrary\steamapps\common\Istrolid"
```

Or set environment variable `ISTROLID_GAME_DIR` to your installed game's folder. To rebuild from scratch: `Run-Istrolid.cmd -Clean`. To build without launching: `Build-Only.cmd`.

The original Steam installation is **not modified**. `.build/` is ignored by Git.

## Make changes with Git

Place modified or new files under `overrides/` mirroring their paths in the game's ASAR. Examples:

- `overrides/main.js` replaces the Electron startup script.
- `overrides/js/istrolid.cat.js` replaces the game bundle.
- `overrides/css/style.css` replaces the game's CSS.

Double-click `Run-Istrolid.cmd` to apply the overrides and launch. Commit only independently authored files or files that you have permission to redistribute. Original unpacked assets and game code stay local in `.build/`.

To inspect the unpacked source, start with `.build/IstrolidR/resources/app/js/istrolid.cat.js`. It retains many `//from src/...` source markers. See `RESEARCH.md` and `tools/split_bundle.py`.

## What “build” means

Istrolid's game logic is JavaScript packaged with Electron. It does **not** need native compilation to run. This launcher prepares an unpacked Electron application from your installed game and tracked overrides, then executes it using the original Electron executable.

This is **not yet** a self-contained clone: it requires the installed official game, and online features can depend on external services. We have not tested launching the built game on a Windows machine from this environment.

## License and ownership

Istrolid is developed/published by treeform; free-to-play does **not** mean its code and assets are open source. This repository holds original build tooling and research notes, not an implied license to redistribute the game. If you have the rights to distribute recovered game files, they can be added separately subject to GitHub's file limits.