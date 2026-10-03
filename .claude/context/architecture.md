# Architecture and key decisions

Part of the project context; see [the index](../PROJECT_CONTEXT.md).

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
- **Model manifest** (`Resources/models.json`, copied into the bundle by `build-app.sh`;
  `ModelManifest.builtIn` is a compiled-in copy a test keeps equal): the list setup and Settings
  offer, and `ModelSpec.catalog`. Entries: id, name, title, repository (none while coming soon),
  kind (`gguf`/`package`), extraFiles, sizeBytes, minimum RAM, availability
  (`available`/`comingSoon`), badge, isDefault, inSetup. Making a model available or the default is
  a JSON edit. Current order: Swift Splash Q4 package `MikeZ75/Swift-Qwen3.8-Flash-Next-V3-Splash`
  (default, Recommended), Swift GGUF, base Splash Q4 package `MikeZ75/Qwen3.8-Flash-Next-V3-Splash`,
  base GGUF. Format tags: GGUF (converted on the first start), Splash Q4 (ready to run).
- **First-run setup** (`SetupCoordinator`, `SetupWindow.swift`, `HubModelDialog.swift`; Core
  `SetupProgress`): a fixed 640×450 "Setup Slipstream" window, step sidebar (Welcome, Slipstream,
  Model, Server), one default button per step (`.id(title)` so the focus ring follows a relabel).
  - **Opens** at launch (after `learnLoginShellPath`) while `!setupCompleted` and Slipstream or the
    model is missing; otherwise `completeSilently()` marks it done. Reopens at the first incomplete
    step; Settings has "Run setup again…". Esc doesn't close it (`cancelOperation` overridden).
  - **Slipstream:** Install (`ReleaseInstaller`, progress bar only once clicked) or "Use existing
    installation…" (`SlipstreamInstallation.chosen`: a release folder, its command, or a checkout;
    too old = no `pull`). A release outside `~/.local` is stored as `slipstreamPath`, tried first by
    `InstallationLocator`.
  - **Model:** scrollable cards from the manifest, "Model from Hugging Face" (the shared
    `HubModelDialog`: owner/name or the page URL via `HubModelID.parse`, checked before use) and
    "Other model" (a folder, validated with `ModelPresence`). "Download and continue" saves the
    choice, checks the disk, starts `ModelDownloader` in the background and moves on.
  - **Server:** endpoint/model/engine box, the download's progress, "Open Web UI after server
    startup" (default on: opens `http://127.0.0.1:<port>/` once the status is Running; gives up if it
    stops). Start closes setup and opens the Stats panel; "Open settings…" finishes setup. A
    "Starting Slipstream" wait window was built and removed again at the user's request (the panel
    is enough).
  - **Preview** (`--setup-preview`): installs, downloads and starts are simulated, settings stay in
    memory; pickers and the Hub check are real (read-only).
- **Model picker** (`ModelPicker.swift`; Settings → Model `ModelChoice`): the menu's "Download
  Model…" opens it first, as the user asked. Settings' Model section lists catalog, custom models and
  a chosen folder, with **Choose from disk…** and **Load from Hugging Face…** (the setup dialog).
  - **Catalog:** **only Qwen3.8-Flash-Next** (Swift + base). The engine loads only
    `splash-packed-q4-qwen4exp` (`runtime/model/ModelDescriptor.mm:324`). The
    `incoai/Qwen3.8-27B-Splash` / `Qwen3.6-35B-A3B-Splash` packages in the launcher's
    `official-models.txt` and `PACKAGE_FORMATS` (from Splash 1.0) downloaded fine (17.4 / 20.9
    GB, ~3 min each) but fail with `unsupported weight format: splash-packed-q4[-moe]`. Tested;
    don't re-add them.
  - **Checking a Hub model** (`ModelPicker.check`): with a Slipstream that has `pull --check`
    (`supportsPullCheck`), its JSON verdict (`PullCheck`); otherwise the app's own `ModelCheck`: Hub
    tree → package (manifest format/schema must be qwen4exp/5) or GGUF (one model: a single file or
    one complete `-0000N-of-0000M` set at the top level; first shard header via a 256 KB `Range`
    request → `general.architecture` must be `qwen4exp`; adds the shared MTP head if the repo lacks
    one). **No size limit** (the old 150 GB cap stood in for "several variants"; the user rejected
    it). Saved to `config.customModels`.
  - `--download <repo>` dev aid starts a catalog model's download.
- **Open Web UI** (menu, ⌘O): opens `http://127.0.0.1:<port>/` in the default browser while the
  server is serving and the web UI is on (`noWebUI` off).
- **App self-update** (`AppUpdate.swift` in Core, `AppUpdater.swift`, `FileDownload.swift`):
  - **Check:** GitHub `releases/latest` of `mzinner/slipstream-menubar-item` (override
    `SLIPSTREAM_MENUBAR_UPDATE_REPO`), at most every 20 h from the poll loop
    (`config.checkForAppUpdates`, default on), or the menu's Check for Updates… (titled "Update to
    <v>…" once one is known). Last check, last attempt and skipped version live in UserDefaults.
    A failed automatic check waits an hour (`retryInterval`): 26.10.1 retried on every 2–3 s poll
    while offline, which would exhaust GitHub's 60/h unauthenticated limit. Requests retry once on
    transient `URLError`s ("The network connection was lost." happened on a first request).
  - **Log:** `/usr/bin/log show --predicate 'subsystem == "local.slipstream.menubar"'` (notice
    level; plain `log` is a zsh builtin). 26.10.1 and older log nothing.
  - **Verified 2026-10-03:** a 26.10.0-labelled copy updated itself to the CI build of 26.10.1 and
    relaunched (~1.4 s); the *released* 26.10.1 zip updated itself to 26.10.2 on its second run
    (its first run failed silently, most likely the lost-connection error it doesn't retry); five
    fresh 26.10.2 launches all checked fine in ~130 ms. The retry itself has not been seen to fire.
  - **Notes:** the window lists the release body's `## Changes` bullets; the release workflow
    writes them from `git log <previous tag>..<tag>`, leaving out `.claude`-only commits.
  - **Install:** download `Slipstream-Menubar.app.<v>.zip`, verify against `SHA256SUMS.<v>.txt`,
    `ditto` into a temp folder, check bundle id, version and `codesign --verify --deep --strict`,
    ask `modelWindow.confirmQuit()`, then `mv` app → backup and staged → app (admin prompt via
    NSAppleScript if the folder isn't writable), start a detached `sh` that waits for the pid,
    removes the backup and `open`s the app, and quit (`UpdateQuit.approved` skips the quit question).
  - A 0.0.0 build (no tag) is never offered an update. Dev flags: `--check-updates`, `--update-now`.
  - `ReleaseInstaller` now uses the same `FileDownload`.
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
- **Swift vs base Qwen3.8-Flash-Next** (from the model READMEs): the Swift build scores 70.3 % vs
  67.6 % on the authors' benchmark at a similar speed in Slipstream, so it stays the default.
- **Smaller models researched (2026-10-02):** none usable.
  - `Qwen/Qwen3.8-27B` is `qwen3_5` (dense, 64 layers, hidden 5120; GGUFs read `qwen35`), and the
    Qwen3.8 distills are `qwen35`/`qwen35moe`.
  - Every real `qwen4exp` model is Flash-Next, and the engine's layout is fixed to its dimensions.
    Low-bit Flash-Next builds (unsloth/AtomicChat/ISTA, IQ quantisations, in sub-folders) are
    re-quantised to the same ~95 GB package, and the converter can't read IQ types.
  - So the check rejects GGUF variants in sub-folders or side by side (not by size any more).
- **Model download** (`ModelSetup.swift`, `ModelDownloader`, `ModelWindow`): "Download Model…"
  shows while `config.model` is missing (`ModelPresence`).
  - **Model:** `ModelSpec.swiftQwen38FlashNext`, the user's choice. The download is
    `slipstream pull <repo>` (the installation's launcher; a checkout sets up its venv first),
    since Slipstream ships `huggingface_hub` itself: no Homebrew or `hf` any more. It downloads
    into the model store `ModelStore.root` (`~/.slipstream/models`, or `SLIPSTREAM_MODELS`),
    `<root>/<owner>/<repo>`, the folder `serve --model <repo>` uses too, so the CLI and the app
    share one copy. `ModelSpec.folder` is derived from the repository, not stored (older settings'
    `~/models/<name>` folders are ignored for catalog models; a configured folder still serves).
  - **MTP head:** the Swift repository has no `MTP/` folder; `pull` fetches
    `nitinpanj/qwen38-flash-next-v3`'s `MTP/mtp-shared-Q4_K_M.gguf` (1.9 GB, pinned revision) into
    the model's folder. `ModelSpec.extraFiles` only adds it to the totals. Without it the engine
    runs with no MTP head: one token per step, measured 20 vs 42 tok/s on Swift V3.
  - **Done or not:** `pull` writes `.slipstream-gguf.json` before downloading and sets
    `"downloaded": true` at the end (`ModelStore.isDownloaded`, also true once `prepared/` exists).
    `ModelPresence.isAvailable(<hub id>)` is that, so "Download Model…" shows until a pull finished.
  - **Order of checks:** RAM ≥ 64 GB (warn), a Slipstream with `pull`
    (`SlipstreamInstallation.supportsPull`; else offer Install/Update Slipstream), disk
    (`DiskCheck`: block unless ≥ 10 GB stay free after the download, the user's rule; warn if
    preparing won't fit: `Preparation.inPlace` = a twentieth + 12 GiB when Slipstream has
    `--keep-gguf` and the setting is off, `.alongside` = the download again, `.none` for packages).
  - **Keep GGUF files after preparing** (`keepGGUFFiles`, default off): passes `serve --keep-gguf`,
    only to a launcher that has it (`supportsKeepGGUF`; older ones keep the files anyway).
  - **Progress:** `pull` prints no machine-readable progress. So the total comes from the Hub tree
    API and the bytes from the allocated size of the folder (partials are
    `.cache/huggingface/download/*.incomplete`; a package's files go to the Hub cache, measured too).
    `TransferEstimator` uses a 20 s window.
  - **Abort:** SIGINT (the launcher `exec`s the download, so it gets it), then SIGTERM at 5 s,
    SIGKILL at 10 s: files already in transfer finish first, which took 21 s in a test. Then ask
    whether to delete the files or keep them (the next pull resumes at the same commit). Quit
    during a download asks and stops it (`applicationShouldTerminate`).
  - **When done:** set `config.model` to the Hub id; on ≥ 64 GB ask to start the server, else point to Settings.
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
  (`preparationSecondsLeft`). The panel opens by itself when preparation begins, and after setup's
  Start for any model.
- **Dev aids:** `--setup`, `--setup-preview`, `--setup-step N` (1–4), `--setup-hub <id or URL>`
  (opens the Hugging Face dialog and checks), `--show-settings`, `--download-model`, `--download <repo>`; `SLIPSTREAM_MENUBAR_MODEL_REPO` with
  `SLIPSTREAM_MODELS=<scratch>` (e.g. `QuantFactory/SmolLM-360M-GGUF`, which pull accepts as GGUF;
  it is not Flash-Next, so only the download is meaningful) and `SLIPSTREAM_MENUBAR_LOG` (for staging a
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
