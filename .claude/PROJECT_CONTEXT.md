# Slipstream Menubar — project context

## Project

Native macOS (Swift 6 / SwiftUI + AppKit) menu bar item that starts, stops and watches a local
[Slipstream](https://github.com/npanj/slipstream) LLM server checkout. The menu follows oMLX's
menu bar app, reduced to: status, Start/Stop/Force Stop, Stats Panel, Settings, About, Quit. A
floating panel shows live serving charts (throughput, KV cache, requests, engine memory) and system
charts (CPU, GPU, memory, swap). Published on GitHub as `mzinner/slipstream-menubar-item` (public,
MIT); first release v26.10.0.

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

## Architecture / key decisions

- **Two targets:** `SlipstreamMenubarCore` (testable: metrics parsing, rates, status resolution,
  config, lock file, system sampling, network addresses) and `SlipstreamMenubar` (AppKit/SwiftUI
  app). SwiftPM only, no Xcode project; `scripts/build-app.sh` assembles and ad-hoc signs the bundle.
- **Server discovery via `<checkout>/build/runtime/serve.lock`** (pid, model, port, host). The
  launcher `execve`s into `server/server.py`, so the lock pid *is* the server. The pid is checked
  with `sysctl(KERN_PROCARGS2)` for `install/launcher.py` or `server/server.py`. This is how a server
  started from a terminal or by an earlier app run is found ("started elsewhere").
- **Spawned with `posix_spawn` + `POSIX_SPAWN_SETSID | CLOEXEC_DEFAULT`**, stdout and stderr to
  `~/Library/Logs/Slipstream/server.log` (the previous log is kept as `.1`). So **Quit leaves the
  server running**, and the next launch re-detects it. The spawned pid is kept in UserDefaults
  (`spawnedServerPid`) so the app recognises its own server after a restart.
- **Liveness:** `/ready` is a *readiness* check: it returns 503 whenever the server is saturated
  (queue full, native status stale, critical memory pressure). It only decides when startup is done.
  After that, "Not responding" means 3 failed `/health` checks in a row. A server first seen at app
  launch counts as Running if `/metrics` shows submitted requests > 0, or our log has `Ready ·`.
- **Rates are counter deltas over a 3 s wall-clock window**, timestamped when the `/metrics`
  response *arrives*. The engine's own `*_tokens_per_second` gauges divide by GPU step time and read
  roughly 15× too high (662 vs. 40 tok/s).
- **History:** `TimeSeries` prunes by age (300 s window, one older point kept for the left edge,
  400-point cap). Charts draw only the window and clip the plot area. Engine history is **kept
  across outages**: `DataGap`s are shaded light gray, a `segment` id breaks lines at gaps, and the
  rate window is reset at each gap.
- **Polling:** 2 s while serving or watched, 1 s while changing state, 3 s when stopped. `/status`
  every 15 s (context limit, KV block tokens).
- **Menu bar item:** the bolt from the server's web UI (a generic Feather-style path, cropped to its
  outline), then two right-aligned stacked readouts in a monospaced 9.4 pt semibold font, in the
  style of Vorssaint's network indicator: **↓ prompt tok/s (incoming) over ↑ output tok/s
  (outgoing)**. Whole numbers only, capped at 400, fixed width ("↑400"). Template image.
  `StatusItemImage.reviewValue` (nil) forces a value for layout review.
- **Settings:** JSON at `~/Library/Application Support/Slipstream/menubar.json`, decoded with
  defaults for missing keys. The API key is in the Keychain and passed via `SLIPSTREAM_V2_API_KEY`.
  "Listen on the network" adds `--host 0.0.0.0`, and is validated against the checkout's launcher
  containing `"--host"`.
- **Panel:** compact view is the default (`@AppStorage("compactStatsPanel")`). The panel fits all
  cards once on first launch, grow-only, until the full layout is reached or the user
  resizes/toggles (`statsPanelUserSized`). There's a 40 pt bottom fade only while there is more to
  scroll (`onScrollGeometryChange` on `visibleRect`). Every chart uses a fixed 34 pt y-axis label
  column, so charts align.
- **Which Slipstream runs** (`Installation.swift`):
  - `InstallationLocator.find` tries `~/.local/bin/slipstream`, then `slipstream` on the app's
    PATH plus the login shell's (`$SHELL -l -i -c`, read once at launch), unless Settings → Run is
    "Source checkout" (`useCheckout`).
  - A release is recognised by `<root>/bin/slipstream` + `release.json` (through the symlink);
    its lock is `~/Library/Application Support/Slipstream-v2/runtime/serve.lock`. A checkout's
    is `build/runtime/serve.lock`.
  - Refresh reads **all** candidate locks, so a server from either kind is found.
  - With nothing installed, the menu shows **Install Slipstream…** instead of Start.
- **Model picker** (`ModelPicker.swift`; Settings → Model `ModelChoice`): the menu's "Download
  Model…" opens it first, as the user asked.
  - **Catalog:** **only Qwen3.8-Flash-Next** (Swift + base). The engine loads only
    `splash-packed-q4-qwen4exp` (`runtime/model/ModelDescriptor.mm:324`). The
    `incoai/Qwen3.8-27B-Splash` / `Qwen3.6-35B-A3B-Splash` packages in the launcher's
    `official-models.txt` and `PACKAGE_FORMATS` (from Splash 1.0) downloaded fine (17.4 / 20.9
    GB, ~3 min each) but fail with `unsupported weight format: splash-packed-q4[-moe]`. Tested;
    don't re-add them.
  - **New Model…** (`ModelCheck`): Hub tree → package (manifest format/schema must be
    qwen4exp/5) or GGUF (first shard header via a 256 KB `Range` request → `GGUFHeader`
    `general.architecture` must be `qwen4exp`; adds the shared MTP head if the repo lacks one).
    Saved to `config.customModels`. Verified against real repos: qwen2 GGUF and safetensors-only
    are rejected; a missing repo returns 401.
  - `--download <repo>` dev aid starts a catalog model's download.
- **Uninstall and Cleanup** (Settings, last section; `Cleanup.swift`, `UninstallWindow.swift`):
  - **Per model:** each downloaded model can be deleted with its size; "Stop and Delete" if the
    server runs it.
  - **Full uninstall:** stops the server, then removes `~/.local/share/slipstream`,
    `~/.local/bin/slipstream` (only if it points into the releases), `Application
    Support/Slipstream-v2` and `/Slipstream`, `Logs/Slipstream`, the ticked models, the Keychain
    API key, the login item and the UserDefaults domains. The app bundle goes to the Trash, then
    the app quits.
  - **Safety:** only known paths, and model folders only when they hold a model (`ModelPresence`).
    Homebrew, hf, `~/.cache/huggingface` and source checkouts are left alone.
  - **Testing:** never run the full uninstall on the user's Mac for a test; the dry run of
    `Cleanup.allItems` listed the 7 expected items.
- **Smaller models researched (2026-10-02):** none usable.
  - `Qwen/Qwen3.8-27B` is `qwen3_5` (dense, 64 layers, hidden 5120; GGUFs read `qwen35`), and the
    Qwen3.8 distills are `qwen35`/`qwen35moe`.
  - Every real `qwen4exp` model is Flash-Next, and the engine's layout is fixed to its dimensions.
    Low-bit Flash-Next builds (unsloth/AtomicChat/ISTA, IQ quantisations, in sub-folders) are
    re-quantised to the same ~95 GB package, and the converter can't read IQ types.
  - So New Model… rejects GGUF variants in sub-folders and anything over 150 GB.
- **Model download** (`ModelSetup.swift`, `ModelDownloader`, `ModelWindow`): "Download Model…"
  shows while `config.model` is missing (`ModelPresence`).
  - **Model:** `ModelSpec.swiftQwen38FlashNext`, the user's choice and the README's command:
    `hf download nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF --local-dir
    ~/models/swift-qwen38-flash-next-v3`. Its repository has no `MTP/` folder, so the app also
    fetches `hf download nitinpanj/qwen38-flash-next-v3 MTP/mtp-shared-Q4_K_M.gguf` (1.9 GB) into
    the same folder (`ModelSpec.extraFiles`), and the totals include it. Without it the engine runs
    with no MTP head (loaded only if `mtp-layer.bin` and `mtp-combiner.bin` exist): one token per
    step. The converter's `Warning: no MTP draft head` line is shown in the panel
    (`LogProgress.missingMTPDraftHead`).
  - **Order of checks:** RAM ≥ 64 GB (warn), `hf` (`brew install hf`; without brew, ask, then
    open Terminal with the official installer in a `.command` file and poll for `brew`), disk
    (`DiskCheck`: block unless ≥ 10 GB stay free after the download, the user's rule; warn if the
    ~same-size prepared copy won't fit).
  - **Progress:** `hf --format json` has no progress (dry run: file list with rounded sizes;
    download: the final path only). So the total comes from the Hub tree API and the bytes from
    the allocated size of the folder (partials are `.cache/huggingface/download/*.incomplete`).
    `TransferEstimator` uses a 20 s window. Measured here: 21 → 53 MB/s, ETA ~32 min for 102.6 GB.
  - **Abort:** SIGINT, then SIGTERM at 5 s, SIGKILL at 10 s (hf ignored SIGINT once). Then ask
    whether to delete the files or keep them (hf resumes). Quit during a download asks and stops
    hf (`applicationShouldTerminate`).
  - **When done:** set `config.model`; on ≥ 64 GB ask to start the server, else point to Settings.
- **GPU wired limit:** before every start on a 64 GB Mac (`MachineCheck.needsGPULimitRaise`: 64…95
  GB), if `raiseGPULimit` and `iogpu.wired_limit_mb` ≠ `gpuWiredLimitMB` (59392), run
  `/usr/sbin/sysctl iogpu.wired_limit_mb=…` through `NSAppleScript … with administrator
  privileges`. If that fails: "Cancel" / "Start Anyway". Settings → Memory shows the current value.
  It was already 59392 on this Mac, so the password prompt is untested here.
- **Running vs. installed version:** an update only re-points `~/.local/bin/slipstream`; a running
  server keeps its version until restarted, and every Start runs the link, so the latest. The
  panel shows the *running* version, from the server's argv (`runningRoot`: the path of
  `server/server.py` or `install/launcher.py` → `release.json`). When it differs from the
  installed one (`pendingUpdate`), an orange line says "… is installed; this server runs …. Stop
  and start it to update/switch", and the menu detail says "restart to update to …".
- **First-start preparation:** for a server the app started, the log's 53 `[DONE]` lines drive a
  progress bar in the panel header, with an ETA from the pace so far
  (`preparationSecondsLeft`). The panel opens by itself when preparation begins.
- **Dev aids:** `--download-model`; `SLIPSTREAM_MENUBAR_MODEL_REPO`/`_MODEL_DIR` (e.g.
  `hf-internal-testing/tiny-random-gpt2`, 12.5 MB) and `SLIPSTREAM_MENUBAR_LOG` (for staging a
  preparation with `fake-server.py --lock-repo … --outage 0 100000`, a fake checkout repo,
  `useCheckout` and `defaults write SlipstreamMenubar spawnedServerPid -int <pid>`).
- **Installer** (`ReleaseInstaller` + `InstallWindow`):
  - GitHub API `releases/latest` of `config.releaseRepository` (default `mzinner/slipstream`) →
    `SHA256SUMS` → `ReleasePackages.select` (the newest `-macos<N>-arm-64bit.zip` with N ≤ the
    local major).
  - The download runs on its own delegate `URLSession` for progress; the API calls use a plain
    session, because async requests on the delegate session never complete.
  - Then CryptoKit SHA-256, `ditto -x -k`, a move to `~/.local/share/slipstream/<version>`, the
    `~/.local/bin/slipstream` symlink, and pruning to the two newest versions.

## Slipstream server contract (what the app relies on)

- **Launch chain:** `./slipstream serve …` → `slipstream-v2` (sh) → `.venv/bin/python
  install/launcher.py`. The launcher takes an `flock` on `build/runtime/serve.lock`, writes `{"pid",
  "model", "port", "host"}` (`host` only with PR #5), and probes `bind((host, port))`. For a GGUF
  folder without `prepared/manifest.json` + `prepared/target/layer-0.bin`, it runs the converter as a
  subprocess. Then it `os.execve`s into `server/server.py` (same pid), which starts the engine
  (`build/slipstream-v2 serve-native`) as a child. The lock keeps its contents after exit.
  `--max-context`/`--max-memory` default to `auto` (256K context here).
- **Signals:** SIGTERM/SIGINT → graceful shutdown, logs `Stopping · releasing engine resources`,
  ~2 s. A model load takes ~11–15 s for a prepared package. GGUF preparation took 214 s with 5 workers.
- **Endpoints:** `GET /` chat UI (off with `--no-webui`); `/health` is static 200 while HTTP is up;
  `/ready` 200/503 = `backend.is_ready()` (can submit, native ready, pressure normal/warning);
  `/status` JSON (top-level `ready`, `maximum_context_tokens`, `kv.block_tokens` and
  `pages_*`, `memory_plan`, `transport.status_stale`; while busy it answers quickly but stale, with
  `"error": "native status response timed out"`); `/metrics` Prometheus, every series three times
  (`slipstream_v2_*`, `slipstream_*`, `splash_*`); OpenAI/Anthropic routes under `/v1/…`.
- **Auth:** with an API key (`--api-key` or `SLIPSTREAM_V2_API_KEY`), everything except
  `GET/HEAD /`, `/index.html`, `/health`, `/ready` and `OPTIONS` needs `Authorization: Bearer <key>`
  or `x-api-key` (401 otherwise).
- **Host header:** accepted are localhost, 127.0.0.1, ::1, the bind address, *the local address the
  connection arrived on* (so a LAN IP works with `--host 0.0.0.0`), and `--allowed-host` names; 403
  otherwise. `<mac>.local` needs `--allowed-host`.
- **Log lines** (stdout, `HH:MM:SS` prefix): `Loading · <model>`, `Ready · <model> · context 256K ·
  http://…`, a `Done · input N · cached N · output N · … TTFT … · prompt X tok/s · decode Y tok/s` line
  per request (the ground truth for speeds), `Stopping · …`, `Memory: growth paused…`. Converter:
  `[Slipstream] Preparing GGUF model from …`, `  [DONE] <part> finished` ×53, `=== Successfully
  prepared … ===`, `error: …` / `[ERROR]`.
- **Metric semantics:**
  - Token counters `decode_output_tokens_total` and `prefill_input_tokens_total`: divide by real
    time, not by `*_wall_milliseconds_total`.
  - KV: `kv_pages_{total,active,cache,free}` × `block_tokens` (32). 12,032 pages ≈ 385K tokens.
  - Memory: `memory_current_bytes` (~155 GB) counts mmapped weights, so the app uses
    `memory_limit_bytes − memory_headroom_bytes` (~52–54 of 55.8 GB).
  - Also used: `memory_pressure{state=…}`, `ttft/itl_p50/p95_milliseconds`, `draft_acceptance_ratio`
    (~0.62–0.72), `cache_hits_total` / `cache_cold_misses_total`, `requests_*_total`,
    `scheduler_{queued,prefilling,decoding}`.
- **Measured here:**
  - Decode 30–56 tok/s (median ~44; the README claims 40–48), prefill ~300–450 tok/s.
  - TTFT 0.4–3 s with the context cached; 44 s for 18K new tokens.
  - The engine pins ~37 GB of experts. System memory sits at ~54 of 64 GB while serving.

## User decisions (keep unless asked to change)

- **Menu bar:**
  - Bolt on the left, 2 pt gap.
  - ↓ prompt on top, ↑ output below (incoming/outgoing as seen from the server); arrows directly
    against the numbers, right-aligned.
  - Integers only, 400 cap, column sized for "↑400". macOS still adds 8 pt per side (57 pt item for
    a 41 pt image).
- **Panel:**
  - One floating window (not submenus) with serving and system cards, refreshing every 2 s.
  - Compact view is the default; the toggle sits left of Stop/Start.
  - Fixed y-axis label column (34 pt) for alignment, with compact `47G`/`4.0K` labels; the prompt
    chart is 6 pt below the output chart.
  - Color dots after the figure labels in every card; chart legends hidden in compact.
  - Sizes itself once (first launch only) and **must never auto-resize** on toggling.
  - Bottom fade of 40 pt only while there is more to scroll. **No always-visible scrollbar.**
  - History kept across outages, with light gray gap areas.
- **Behaviour:** Quit leaves the server running; the app detects a running server on launch and
  must not mislabel a busy one ("Not responding" / "Loading model…" were both bugs).
- **Settings:** the Access section has an API key (Generate/Copy), "Listen on the network", and
  Allowed hosts with explanations.
- **Repo:** Swift; local NAS repo first, now public on GitHub (MIT) with the history credited to the
  private account via noreply; releases versioned `vYY.MM.N` (v26.10.0 = October 2026).

## Current state

- **Working and verified:**
  - Start/Stop through the menu (SIGTERM → clean "Stopping"; SIGKILL after 30 s).
  - Detection on launch, staying Running under load, gap shading, memory stable (~12 MB with the
    panel closed, ~160–168 MB with it open, of which ~90 MB is GPU-owned graphics).
  - 31 unit tests, plus the release workflow.
- **Released:** v26.10.0 (ad-hoc signed, not notarized; users need *Open Anyway* or `xattr -dr
  com.apple.quarantine`).
- **Not verified by Claude:** clicking Settings or the compact toggle in the live UI, Open at login
  (needs the app in /Applications), the bottom-fade behaviour in the live window. Screenshots in the
  README were taken by the user.
- **Known:** the CI log warns that `actions/checkout@v4` and `softprops/action-gh-release@v2` target
  Node 20 (forced to Node 24).

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


## Next steps

1. Bump `actions/checkout` and `softprops/action-gh-release` once versions targeting Node 24 exist.
2. Optionally reduce the menu bar item's macOS padding (8 pt per side) with a fixed
   `statusItem.length`. Offered, not decided.
3. Decide whether the 400 cap on the readout stays (prompt rates reach ~450).
4. Long-run (1 h) memory check with the panel open, to settle the earlier RSS creep for good.
5. Notarization would need a paid Developer ID.
6. Upstream PRs npanj/slipstream#3, #4 and #5 are open. When they merge, rebase the Slipstream fork
   (git drops identical patches; squash-merged ones need `rebase -i`). Then remove the
   `local/all-fixes` branch and the `fork` remote there.
7. The release workflow only runs on tags; a push/PR workflow running `swift test` would catch
   Swift 6.2 breakage earlier.
8. `target/draft-vocab.bin` is not produced by the GGUF path (optional; it would speed up the MTP
   draft head). It is on the Hub in `nitinpanj/Swift-Qwen3.8-Flash-Next-Splash`.

## Gotchas / things not to repeat

- `ImageRenderer` renders a `ScrollView` blank: snapshot `StatsContent`, not `StatsView`. Buttons
  render as yellow 🚫 placeholders in snapshots.
- `screencapture` is not permitted from the terminal, and System Events can't click menus (no
  Accessibility permission). Visual checks go through `--snapshot`. Ask the user to click.
- Rebuilding/relaunching kills background memory measurements, because they key on the app process.
- `CFFIXED_USER_HOME` does not redirect the config; use `SLIPSTREAM_MENUBAR_CONFIG`. A test
  instance pointed at the real checkout follows its `serve.lock` to the real server: give fakes
  their own repo path, with a lock whose pid's argv ends in `server/server.py`.
- `onScrollGeometryChange` does not fire for the initial layout; use `onGeometryChange` on the
  content. `contentOffset + containerSize` miscounts title bar insets; use `visibleRect`.
- Swift memberwise init takes arguments in declaration order (`gaps` must come before `series` in
  `SeriesChart`).
- `sips --cropOffset` crops from the middle, not the top.
- Commits must use the GitHub noreply address `37372663+mzinner@users.noreply.github.com` (set in
  the repo's local git config), never the work email.
- **The agent's background tasks are killed after 2 hours**, and a server started inside one dies
  with it (it happened at 19:03). Detach long-lived processes (see Testing recipes).
- SwiftUI `Text("\(int)")` uses locale grouping (German: `8.090`); use `Text(verbatim:)` for ports,
  pids and similar.
- Samples must be timestamped when `/metrics` arrives: stamping before the request made a 40 tok/s
  request read as 65.
- One-second rate deltas swing between 0 and 2× because MTP drafts in bursts; hence the 3 s window.
- `git cherry-pick` has no `-q`; `gh repo fork --remote` cannot be combined with a repo argument.
- The engine's `decode_tokens_per_second` (~660) is not a client-facing rate. Never display it.

## Related repos

- `~/git/slipstream`: Slipstream checkout. On `main`, which tracks the fork `mzinner/slipstream`:
  upstream plus PRs #3 (issue #1 fixes), #4 (GGUF conversion without reference, memory caps) and #5
  (`serve --host`) as a linear stack. Remotes: `upstream` (npanj), `mzinner` (fork), `fork`
  (mariadb-MikeZinner, holds the open PR branches). Update with `git fetch upstream && git rebase
  upstream/main && git push --force-with-lease mzinner main`.
- Remotes of this repo: `github` (`mzinner/slipstream-menubar-item`) and `origin` (NAS,
  `ssh://192.168.10.245/volume1/Git/slipstream-menubar-item`). Push to both.

### Slipstream-side work from this session

- **Issue npanj/slipstream#1 → PR #3:**
  - The launcher runs the GGUF converter as its own process. `install/models.py` shadowed the
    repo's `models/` package, and the converter's spawn-started workers re-ran the launcher.
  - `dev/tools/sharded_gguf_reader.py` uses `SLIPSTREAM_GGML_LIB` or compiles
    `dev/tools/fast_dequant.c` into `build/libslipstream-dequant.dylib`, instead of a hardcoded
    libggml path.
  - Fixed `fp16_to_fp32` in that C file; the 6 kernels are now bit-exact against `gguf`'s
    dequantizers.
- **Issue #2 (filed) → PR #4:**
  - `ngram.bin` is converted from `per_layer_token_embd.weight` (Q4_0, 160 × 320,001,536, in
    512K-row chunks, 29.8 GiB). The PLE norms are stored as 1 + weight in GGUF.
  - The tokenizer comes from `Qwen/Qwen3.8-Flash-Next@de4b8e4d…`; the draft is a placeholder; a
    reference package is optional and never the output itself.
  - Experts are streamed one at a time (peak 6.5 → 4.1 GB per layer); workers = RAM / 12 GiB (5 on
    64 GB; 8 workers ran the Mac out of memory). The manifest is written last.
- **PR #5:** `serve --host` passed to the server; `serve.lock` records `host`.
  Tested over the LAN: 401/200/403 behave as documented above.
- **Fork releases** (`mzinner/slipstream`, own commits on top of the PR stack on `main`):
  - **Workflow:** `.github/workflows/release.yml` on `v*` tags, on `macos-26` (Xcode 26.6 has the
    Metal toolchain preinstalled; a probe proved `make all` takes 31 s and `make package` 47 s).
  - **Steps:** `make package RELEASE_VERSION=<v>`, build the dequantization dylib, then repackage
    `dist/splash-<v>-arm64-macos26.tar.gz` as `slipstream-<v>-macos26-arm-64bit.zip`.
  - **Added to the package:** `bin/slipstream` (realpath wrapper → `python/bin/python3
    install/launcher.py`), the GGUF converter (`models/qwen4exp/tools`, `dev/tools`) and
    `build/libslipstream-dequant.dylib`, so no Xcode is needed on the user's Mac.
  - **Checks and outputs:** smoke-tested in CI; publishes the zip (71 MB), `SHA256SUMS` and
    `install.sh`, with MariaDB-Shell-style install notes.
  - **`install.sh`** (POSIX sh, our own code modelled on mariadb-shell's GPL script): env
    `SLIPSTREAM_TAG/PREFIX/BINDIR/REPO/TOKEN`, a `gh auth token` fallback, keeps 2 versions.
  - **v26.10.1:** the converter looks for the MTP sidecar only next to the model, takes a
    reference package only via `--reference` (it used to search fixed folders of the author's other
    model and quietly mix in their files), and warns with the `hf` command when no MTP head is found.
    The upstreamable commit is alone on branch `fix/converter-own-folder` (stacked on PR #4's
    branch) for a later PR.
  - **Upstream CI** is disabled in the fork's settings (`gh workflow disable`) rather than edited,
    to keep `ci.yml` rebase-clean. v26.10.0 is published.
  - **Verified on this Mac:** the app's installer installed it into `~/.local`, and it serves the
    prepared model correctly (17 × 23 = 391, "Tokyo").

## Git state

```
$ git status --short
 M .claude/PROJECT_CONTEXT.md
?? scripts/fake-server.py
$ git branch --show-current
main
```

At checkpoint time: this file and the new `scripts/fake-server.py` are about to be committed
together; everything else is committed and pushed to both remotes.
