# Slipstream Menubar — project context

## Project

Native macOS (Swift 6 / SwiftUI + AppKit) menu bar item that starts, stops and watches a local
[Slipstream](https://github.com/npanj/slipstream) LLM server checkout. The menu follows oMLX's
menu bar app, reduced to: status, Start/Stop/Force Stop, Stats Panel, Settings, About, Quit. A
floating panel shows live serving charts (throughput, KV cache, requests, engine memory) and system
charts (CPU, GPU, memory, swap). Published on GitHub as `mzinner/slipstream-menubar-item` (public,
MIT); first release v26.10.0.

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

## Layout

| Path | What |
|---|---|
| `Sources/SlipstreamMenubarCore/` | testable logic: metrics, rates, status, config, installation, model checks, cleanup, system sampling |
| `Sources/SlipstreamMenubar/` | AppKit menu, server control, SwiftUI panel, settings, installer and download windows |
| `Tests/SlipstreamMenubarCoreTests/` | XCTest suite and the `/metrics` fixture |
| `scripts/` | `build-app.sh`, `fake-server.py`, `make-icon.swift` |
| `.github/workflows/release.yml` | tag → tested, signed build and GitHub release |

## Context files

| File | What is in it |
|---|---|
| [context/architecture.md](context/architecture.md) | how the app works and why: targets, discovery, liveness, rates, history, installer, model download and picker, uninstall, GPU limit, preparation progress |
| [context/slipstream.md](context/slipstream.md) | what the app relies on from the Slipstream server, measured numbers, the Slipstream-side work and the fork, related repos |
| [context/development.md](context/development.md) | environment, testing recipes, files that matter, release process |

## Current state

- **Working and verified:**
  - Start/Stop through the menu (SIGTERM → clean "Stopping"; SIGKILL after 30 s).
  - Detection on launch, staying Running under load, gap shading, memory stable (~12 MB with the
    panel closed, ~160–168 MB with it open, of which ~90 MB is GPU-owned graphics).
  - Installing Slipstream from the fork's release (v26.10.1 now in `~/.local`, 26.10.0 kept), the
    model download flow (tested with a tiny repo plus an extra file), New Model… checks against
    real repos, the uninstall dry run (7 items), the running vs installed version display.
  - Open Web UI (⌘O) works; the user confirmed it after a rebuild and relaunch.
  - Settings observe the server controller, so the version shown refreshes after an update.
  - 64 unit tests, plus the release workflow.
- **Released:** v26.10.0 only (ad-hoc signed, not notarized; users need *Open Anyway* or `xattr -dr
  com.apple.quarantine`). Everything since (installer, model download and picker, GPU limit,
  preparation progress, Open Web UI, Uninstall and Cleanup) is committed and pushed but unreleased.
- **Not verified by Claude:** clicking Settings or the compact toggle in the live UI, Open at login
  (needs the app in /Applications), the bottom-fade behaviour in the live window, a real full
  uninstall (never run it on the user's Mac). Screenshots in the README were taken by the user.
- **Known:** the CI log warns that `actions/checkout@v4` and `softprops/action-gh-release@v2` target
  Node 20 (forced to Node 24).

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
8. Tag a new app release (e.g. v26.10.1) to ship the work since v26.10.0. Not asked for yet.
9. Fork: the launcher now refuses the Splash 1.0 packages (minimal version, finished
   2026-10-02): `923c9fa` on `main`, and the same change alone on `fix/v2-only-packages`
   (`b2d9640`, on `upstream/main`) for a later PR. Not pushed and not released yet. Left out on
   purpose: `ci.yml`'s model list, `dev/native.mk` vision fixtures, tests that use the old names as
   example ids, `DEVELOPMENT.md`, benchmarks.
10. `target/draft-vocab.bin` is not produced by the GGUF path (optional; it would speed up the MTP
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

## Git state

```
$ git status --short
 M .claude/PROJECT_CONTEXT.md
?? .claude/context/
$ git branch --show-current
main
```

At checkpoint time: the context was split into this index and `.claude/context/*.md`; those files
are uncommitted. Everything else (up to `53ad728`) is committed and pushed to both remotes.
