# Development: environment, testing, files and releases

Part of the project context; see [the index](../PROJECT_CONTEXT.md).

## Environment

- **Machine:** Apple M5 Pro (20 GPU cores), 64 GB, macOS 26.6.2. Display 1920×1080 pt (4K panel);
  the panel's usable screen height is 1050 pt.
- **Toolchain:** Xcode 27 / Swift 6.4 locally. **CI builds with Swift 6.2.4** (GitHub `macos-15` +
  `setup-xcode latest-stable`), so the code must keep compiling there. The deployment target is
  macOS 15 (the Slipstream engine itself needs 26.4).
- **Accounts:** `gh` is logged into the private account `mzinner` (it was `mariadb-MikeZinner`
  earlier; the upstream PRs #3–#5 were opened from that one). The NAS git server is
  `ssh://192.168.10.245/volume1/Git/<name>`: bare repos, no `.git` suffix, `git init --bare -b main`.
- **Model in use:** `~/models/qwen38-flash-next-v3`: 3 GGUF shards (~102 GB), `MTP/mtp-shared-Q4_K_M.gguf`,
  `prepared/` (~100 GB, written by the converter on first serve). Served as
  `local/qwen38-flash-next-v3` on 127.0.0.1:8090.
- **App config on this Mac** (`menubar.json`): repo `~/git/slipstream`, the model above, port 8090,
  not listening on the network, no API key. UserDefaults domain `local.slipstream.menubar`.

## Testing recipes

- **Unit tests:** `make test` (31 XCTest cases, including a real `/metrics` capture in
  `Tests/.../Fixtures/metrics.txt`). `make app` builds `build/Slipstream Menubar.app`; `make run`
  opens it with `--show-panel`; `make install` copies it to /Applications (needed for Open at login).
- **Visual checks:**
  - `open "build/Slipstream Menubar.app" --args --show-panel --snapshot /path/p.png`.
  - It writes `p.menubar.png` (menu bar samples at 4×) at once, `p.widths.txt` (status item vs.
    image width) after 8 s, and `p.png` (panel content at 2×) after 45 s.
  - Send load meanwhile so charts have data:
    `curl http://127.0.0.1:8090/v1/chat/completions -d '{"model":"local/qwen38-flash-next-v3",…}'`.
- **Without touching the user's app or server:**
  - Run the bare binary `.build/release/SlipstreamMenubar` (not `.build/arm64-apple-macosx/…`).
    Its UserDefaults domain is `SlipstreamMenubar`, so set e.g.
    `defaults write SlipstreamMenubar compactStatsPanel -bool true`, then `defaults delete` afterwards.
  - Use `SLIPSTREAM_MENUBAR_CONFIG=<json>`, and stop it by its PID.
  - With `scripts/fake-server.py` (`--outage START END`, `--busy`, `--served N`, `--lock-repo DIR`),
    and a config whose `repoPath` is the fake repo, it shows gaps, busy-at-launch etc.
- **Saturation (`/ready` 503):** three concurrent chat requests with a ~5K-token prompt.
- **Memory:** sample `footprint -p <pid>` (`phys_footprint`) once a minute for over 5 minutes, with
  the panel open and closed. Don't rebuild during it.
- **Start/Stop:** ask the user to click (see Gotchas), and watch `serve.lock`, `/ready` and the log
  with a 1 s loop.
- **Restarting the user's server outside the app:** detach it fully, with a Python
  `fork()`/`setsid()`/`execv("./slipstream", […])`, output to `~/Library/Logs/Slipstream/server.log`.

## Files that matter

- `Sources/SlipstreamMenubarCore/ServerStatus.swift`: `ServeLock`, process inspector, `LogProgress`
  (53 GGUF preparation parts), `ServerStatus`, `StatusResolver`.
- `Sources/SlipstreamMenubarCore/EngineSample.swift`: `/metrics` → `EngineSample`, `EngineRates`,
  `TimeSeries` (window, segments), `DataGap`.
- `Sources/SlipstreamMenubarCore/ServerConfig.swift`: config, serve arguments, validation,
  `ConfigStore` (`SLIPSTREAM_MENUBAR_CONFIG` override for test instances).
- `Sources/SlipstreamMenubarCore/SystemSampler.swift`: CPU ticks, IOKit GPU utilisation,
  `vm_statistics64`, swap, pressure.
- `Sources/SlipstreamMenubar/ServerController.swift`: refresh/probe, `posix_spawn`, stop, exit
  reaping, `hasServedRequests`.
- `Sources/SlipstreamMenubar/StatsModel.swift`: sampling, rates, gaps, history.
- `Sources/SlipstreamMenubar/StatsPanel.swift`: panel window (fit-to-content), `StatsView` (fade),
  cards, `SeriesChart`.
- `Sources/SlipstreamMenubar/StatusItemImage.swift`: menu bar drawing.
- `Sources/SlipstreamMenubar/AppDelegate.swift`: wiring, poll loop, `--show-panel`, `--snapshot`
  (renders the panel and menu bar samples to PNGs).
- `.github/workflows/release.yml`: `v*` tag (or a manual run with an existing tag) → test, build with
  `MARKETING_VERSION`, then `Slipstream-Menubar.app.<ver>.dmg` (app + Applications link),
  `….zip` and `SHA256SUMS.<ver>.txt` to a GitHub release.
- `.claude/commands/checkpoint.md`: the `/checkpoint` command that maintains this file (committed).
- `Sources/SlipstreamMenubarCore/Installation.swift`: `SlipstreamInstallation`, `InstallationLocator`
  (find, `serveLocks`, `loginShellPath`), `ReleasePackages` (select, version, superseded).
- `Sources/SlipstreamMenubar/ReleaseInstaller.swift`, `InstallWindow.swift`: download/verify/
  unpack/link with phases, and the progress window. `--install-latest` (dev aid) opens it and starts.
- `scripts/fake-server.py`: stand-in server for tests (gaps, busy `/ready`, served requests,
  serve.lock).
- `Tests/SlipstreamMenubarCoreTests/Fixtures/metrics.txt`: a real `/metrics` capture (also used by
  the fake server).
- `Resources/Info.plist`: bundle id `local.slipstream.menubar`, `LSUIElement`, macOS 15, placeholder
  version `0.0.0`. `build-app.sh` sets the real one: `MARKETING_VERSION` (from CI) or else the
  latest `v*` tag, so local `make app` builds also show 26.10.0 in Finder. `CFBundleVersion` =
  `git describe`.
- `Assets/MenuBarItem.png`, `Assets/StatsPanel.png`: README screenshots taken by the user.
- `scripts/make-icon.swift` → `Resources/AppIcon.icns` (committed, 91 KB; `CFBundleIconFile
  AppIcon`): the web UI's bolt as a white outline, no glow (user's choice), on an indigo→violet
  rounded tile (macOS grid: 824/1024 tile, radius 185). Rerun it after changing the design:
  `swift scripts/make-icon.swift Resources/AppIcon.icns preview.png`. Size rules learned:
  - `NSGradient` dithers: the gradient is drawn as flat rows instead (162 → 32 KB at 1024 px).
  - Each pixel size is written once (16@2x, 128@2x, 256@2x would repeat 32/256/512 px).
  - A blurred glow roughly doubles the size (189 KB). The original was 532 KB.
  - `pngquant` is not installed.

## Release process

1. Commit and push `main` to both remotes.
2. `git tag -a vYY.MM.N -m "Slipstream Menubar YY.MM.N"`, then `git push github vYY.MM.N` (and
   `origin`).
3. The workflow (~1–3 min, macOS arm64 runners can queue) tests, builds, and publishes
   `Slipstream-Menubar.app.<ver>.dmg` (~354 KB), `Slipstream-Menubar.app.<ver>.zip` (~294 KB) and
   `SHA256SUMS.<ver>.txt` with install notes. Watch it with
   `gh run watch <id> -R mzinner/slipstream-menubar-item`. To rebuild an existing release's files:
   `gh workflow run release.yml -R mzinner/slipstream-menubar-item -f tag=vYY.MM.N`. It uploads
   the new files but does not delete old ones; remove those with `gh release delete-asset`.
   A `.app` cannot be a release asset by itself (it is a folder), hence the zip and the dmg.
4. Verify with `gh release download`, `shasum -a 256 -c`, the `Info.plist` version, and
   `codesign --verify --deep --strict`.
