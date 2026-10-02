# Slipstream Menubar — project context

## Project

Native macOS (Swift 6 / SwiftUI + AppKit) menu bar item that starts, stops and watches a local
[Slipstream](https://github.com/npanj/slipstream) LLM server checkout. The menu follows oMLX's
menu bar app, reduced to: status, Start/Stop/Force Stop, Stats Panel, Settings, About, Quit. A
floating panel shows live serving charts (throughput, KV cache, requests, engine memory) and system
charts (CPU, GPU, memory, swap). Published on GitHub as `mzinner/slipstream-menubar-item` (public,
MIT); first release v26.10.0.

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
- `.github/workflows/release.yml`: `v*` tag → test, build with `MARKETING_VERSION`, zip and SHA-256
  to a GitHub release.
- `.claude/commands/checkpoint.md`: the `/checkpoint` command that maintains this file (committed).

## Next steps

1. Bump `actions/checkout` and `softprops/action-gh-release` once versions targeting Node 24 exist.
2. Optionally reduce the menu bar item's macOS padding (8 pt per side) with a fixed
   `statusItem.length`. Offered, not decided.
3. Decide whether the 400 cap on the readout stays (prompt rates reach ~450).
4. Long-run (1 h) memory check with the panel open, to settle the earlier RSS creep for good.
5. Notarization would need a paid Developer ID.

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

## Related repos

- `~/git/slipstream`: Slipstream checkout. On `main`, which tracks the fork `mzinner/slipstream`:
  upstream plus PRs #3 (issue #1 fixes), #4 (GGUF conversion without reference, memory caps) and #5
  (`serve --host`) as a linear stack. Remotes: `upstream` (npanj), `mzinner` (fork), `fork`
  (mariadb-MikeZinner, holds the open PR branches). Update with `git fetch upstream && git rebase
  upstream/main && git push --force-with-lease mzinner main`.
- Remotes of this repo: `github` (`mzinner/slipstream-menubar-item`) and `origin` (NAS,
  `ssh://192.168.10.245/volume1/Git/slipstream-menubar-item`). Push to both.

## Git state

```
$ git status --short
$ git branch --show-current
main
```

Clean working tree; `.claude/PROJECT_CONTEXT.md` and `.claude/commands/checkpoint.md` are committed.
