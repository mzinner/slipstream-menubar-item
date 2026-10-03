# Slipstream Menubar — project context

## Project

Native macOS (Swift 6 / SwiftUI + AppKit) menu bar item that starts, stops and watches a local
[Slipstream](https://github.com/npanj/slipstream) LLM server checkout. The menu follows oMLX's
menu bar app, reduced to: status, Start/Stop/Force Stop, Stats Panel, Open Web UI, Settings,
About, Check for Updates, Quit. A first-run setup wizard installs Slipstream and a model and
starts the server; the app also installs Slipstream and models from the menu, and updates itself. A
floating panel shows live serving charts (throughput, KV cache, requests, engine memory) and system
charts (CPU, GPU, memory, swap). Published on GitHub as `mzinner/slipstream-menubar-item` (public,
MIT); latest release v26.10.5. One-line install:
`curl -fsSL https://github.com/mzinner/slipstream-menubar-item/raw/main/install.sh | sh`.

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
- **Setup wizard:** sidebar layout from the user's design (since deleted; not in git); native
  controls; window "Setup Slipstream"; Welcome uses the app icon and Slipstream's description; the
  Stats panel (not a separate wait window) shows startup; "Open Web UI after server startup" on by
  default; full model names with a GGUF / Splash Q4 tag; the Swift Splash Q4 package is the default.
- **Models:** no size limit on Hub models (one model per repository instead); checks done by
  Slipstream (`pull --check`) rather than the app where possible; converted packages are published
  on Hugging Face as MikeZ75, public, license as the source, crediting the original authors.
- **Settings:** "Keep GGUF files after preparing" (default off) with a one-line note, no versions;
  models are added with "Choose from disk…" / "Load from Hugging Face…".
- **Releases:** a release nobody downloaded yet is replaced in place (move the tag) rather than
  bumped; the dmg is `Slipstream-Menubar.<v>.dmg`; notes show Install before Changes.
- **Repo:** Swift; local NAS repo first, now public on GitHub (MIT) with the history credited to the
  private account via noreply; releases versioned `vYY.MM.N` (v26.10.0 = October 2026).

## Layout

| Path | What |
|---|---|
| `Sources/SlipstreamMenubarCore/` | testable logic: metrics, rates, status, config, installation, model checks, cleanup, system sampling |
| `Sources/SlipstreamMenubar/` | AppKit menu, server control, SwiftUI panel, settings, installer and download windows |
| `Tests/SlipstreamMenubarCoreTests/` | XCTest suite and the `/metrics` fixture |
| `scripts/` | `build-app.sh`, `fake-server.py`, `make-icon.swift`, `stage-hub-package.py` |
| `Resources/` | `Info.plist`, `AppIcon.icns`, `models.json` (the model manifest) |
| `install.sh` | one-line installer, attached to every release |
| `.github/workflows/release.yml` | tag → tested, signed build and GitHub release |

## Context files

| File | What is in it |
|---|---|
| [context/architecture.md](context/architecture.md) | how the app works and why: targets, discovery, liveness, rates, history, installer, model manifest, setup wizard, model download, picker and checks, app self-update, uninstall, GPU limit, preparation progress |
| [context/slipstream.md](context/slipstream.md) | what the app relies on from the Slipstream server (incl. in-place preparation, `pull --check`), measured numbers, the fork and its branches, the Hugging Face packages, related repos |
| [context/development.md](context/development.md) | environment, testing recipes (setup preview, installer, Hub end to end), files that matter, release process (incl. replacing a release) |

## Current state

- **Working and verified:**
  - Start/Stop through the menu (SIGTERM → clean "Stopping"; SIGKILL after 30 s).
  - Detection on launch, staying Running under load, gap shading, memory stable (~12 MB with the
    panel closed, ~160–168 MB with it open, of which ~90 MB is GPU-owned graphics).
  - Installing Slipstream from the fork's release, the model download flow, the uninstall dry run
    (7 items), the running vs installed version display, Open Web UI (⌘O), app self-update
    (26.10.1 → 26.10.2), downloads through `slipstream pull` into `~/.slipstream/models`.
  - Setup wizard: every step seen in screenshots (debug build, preview mode); the Hugging Face
    dialog's check against the real Hub, through Slipstream's `pull --check` and the fallback.
  - `install.sh` from the published release into a scratch folder (checksum, no quarantine left).
  - Converter in place on a clone of the Swift GGUF: peak 102.6 GiB, byte-identical output.
  - The Swift Splash Q4 package downloaded from the Hub, `verify --full`, served correctly.
  - 92 unit tests, plus the release workflow.
- **Released:** app v26.10.0 … v26.10.5. 26.10.4: setup wizard, in-place preparation setting,
  `install.sh`. 26.10.5 (replaced in place three times; current files from `18a6ab7`): Splash Q4
  packages as default, "Open Web UI after server startup", Stats panel after setup. Fork
  Slipstream v26.10.4: in-place preparation, `--keep-gguf`, `pull --check`. Ad-hoc signed, not
  notarized (`install.sh` clears the quarantine; a browser download needs *Open Anyway*).
- **Hugging Face:** `MikeZ75/Swift-Qwen3.8-Flash-Next-V3-Splash` and
  `MikeZ75/Qwen3.8-Flash-Next-V3-Splash` are public (see slipstream.md).
- **This Mac:** Slipstream 26.10.3 in `~/.local` (26.10.2 kept); 26.10.4 not installed here. Both
  Flash-Next GGUF models with their shards and `prepared/` in `~/.slipstream/models/nitinpanj/`; the
  settings serve `nitinpanj/qwen38-flash-next-v3`. No server running. `iogpu.wired_limit_mb` is
  59392.
- **The user's copy** runs from `build/` (26.10.2 build); its update check offers 26.10.5. The user
  ran the wizard on another Mac (found the focus-ring bug, fixed).
- **Not verified by Claude:** clicking through setup for real (Install, a real download, Start,
  the browser opening, the Stats panel opening after setup), the focus-ring fix (needs keyboard
  focus), the base Splash Q4 package downloaded from the Hub, Open at login, a real full uninstall
  (never run it on the user's Mac).
- **Known:** the CI log warns that `actions/checkout@v4` and `softprops/action-gh-release@v2` target
  Node 20 (forced to Node 24). The model author's `nitinpanj/Swift-Qwen3.8-Flash-Next-Splash` is an
  unfinished upload of the same Swift package (layers 0–19).

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
8. A stable signing identity (self-signed certificate in the release workflow, or a Developer
   ID) would stop macOS asking for Keychain access after each update. Offered, not decided.
9. Fork: `feat/gguf-hub-install` → `feat/slipstream-pull` → `feat/gguf-low-disk-prepare` →
   `feat/pull-check` are upstream-ready (see slipstream.md); open them as PRs after #3/#4 merge.
   Slipstream's README still says `hf download` + serve a folder (the author's text, left alone).
10. Fork: the launcher now refuses the Splash 1.0 packages (minimal version, finished
   2026-10-02): `923c9fa` on `main`, and the same change alone on `fix/v2-only-packages`
   (`b2d9640`, on `upstream/main`) for a later PR. Pushed; released as fork v26.10.2. Left out on
   purpose: `ci.yml`'s model list, `dev/native.mk` vision fixtures, tests that use the old names as
   example ids, `DEVELOPMENT.md`, benchmarks.
11. Suggested to the user: install the 26.10.3 dmg into /Applications (Open at login needs it,
   and updates then have a normal home).
12. `target/draft-vocab.bin` is not produced by the GGUF path; the Hub packages carry the author's
   copy. The converter could write one (`models/qwen4exp/tools/draft_vocab.py`).
13. The menu's Download Model… window still has its own "New Model…" section; offered to switch it
   to the shared Hugging Face dialog, not decided.
14. Installing Slipstream 26.10.4 on this Mac: the next serve of each prepared GGUF model deletes
   its shards (~191 GB) unless "Keep GGUF files" is on; tell the user first.
15. Maybe tell nitinpanj about the published Splash Q4 packages (their own Swift upload is
   unfinished).

## Gotchas / things not to repeat

- `ImageRenderer` renders a `ScrollView` blank: snapshot `StatsContent`, not `StatsView`. Buttons
  render as yellow 🚫 placeholders in snapshots.
- System Events can't click menus (no Accessibility permission); ask the user to click.
  `screencapture -x` works from the terminal now (2026-10-03); `-R x,y,w,h` takes points, not
  pixels. `--snapshot` still renders the panel without screen access.
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
- `scripts/build-app.sh` replaces `build/Slipstream Menubar.app`, which the user's running copy may
  have been started from. Build test copies, then copy them elsewhere, and rebuild `build/` cleanly.
- In zsh, `log` is a builtin (use `/usr/bin/log`), and `echo =====` fails (`=word` expansion).
  `Logger.info` is not kept in the log store; the updater logs at `notice`.
- Swift traps on an inverted range (`8192...ram` on a runner with < 8 GB): compare instead.
- A non-interactive shell starts `cmd &` with SIGINT ignored, so `kill -INT` on it tests nothing;
  start the process from Python (`preexec_fn` restoring `SIG_DFL`), as `Process` does.
- A long `"#…"# + "#…"#` raw-string concatenation inside `Data(...)` fails to type-check
  ("no exact matches"); build the `String` first.
- SwiftUI: a `Button` whose label changes keeps its focus ring at the old size: give it `.id(title)`.
  A `TextField` in a `.sheet` can write `""` back into its binding as the sheet appears: set the
  text before presenting, and match async results by a counter, not by the text. `Text("a" + "b")`
  is a `String`, so `**bold**` stays literal: use one literal.
- Python scripts using `ProcessPoolExecutor` need `if __name__ == "__main__":` on macOS (spawn).
- Foreground `sleep` is blocked in this environment: wait with an `until …; do sleep N; done` loop.
- `hf upload-large-folder` (deprecated for `hf upload`, still works) prints status every minute;
  Xet dedups against data already on the Hub. Detach long uploads (2-hour task limit).
- Moving a release tag: GitHub serves the old assets for a minute or two afterwards.

## Git state

```
$ git status --short
 M .claude/PROJECT_CONTEXT.md
 M .claude/context/architecture.md
 M .claude/context/development.md
 M .claude/context/slipstream.md
$ git branch --show-current
main
```

At checkpoint time: only this checkpoint's context edits are uncommitted; they are committed and
pushed to both remotes right after. `main` (`18a6ab7` before the checkpoint), `feat/setup-wizard`
(merged) and tags up to v26.10.5 are on both remotes. Slipstream fork: `main` (`9ada146`), tag
v26.10.4, and the branches `feat/gguf-low-disk-prepare` and `feat/pull-check` are on `mzinner`.
