# Slipstream Menubar

A macOS menu bar item that starts, stops and watches a local
[Slipstream](https://github.com/npanj/slipstream) server, with a floating panel of
live serving and system charts. The menu design follows
[oMLX](https://github.com/jundot/omlx)'s menu bar app, reduced to the essentials.

The item shows Slipstream's bolt and, while serving, two live readouts in the style of
[Vorssaint](https://github.com/vorssaint/vorssaint-utils)'s network indicator: ↓ prompt
tokens per second (incoming) over ↑ output tokens per second (outgoing).

```
●  Running
   qwen38-flash-next-v3 · :8090
   ─────
   Stop Server              (Start Server when stopped; Force Stop when stuck)
   ─────
   Stats Panel        ⌘S
   ─────
   Settings…          ⌘,
   About Slipstream Menubar
   ─────
   Quit               ⌘Q
```

## Requirements

- macOS 15 or later on Apple Silicon (the Slipstream engine itself needs 26.4)
- Xcode or the Command Line Tools with Swift 6
- A built Slipstream source checkout (`make` in the checkout)

## Build and run

```sh
make test      # unit tests for the core logic
make app       # build/Slipstream Menubar.app, signed ad hoc
make run       # build and open it with the stats panel showing
make install   # copy it to /Applications
```

On first launch, Settings opens if no model is set. The configuration is stored in
`~/Library/Application Support/Slipstream/menubar.json`, and the API key in the login
Keychain.

## How it works

- **Status.** The launcher records its pid, model and port in
  `<checkout>/build/runtime/serve.lock` and then `execve`s into `server/server.py`, so
  that pid is the server. The app reads the lock, checks that the pid is a live
  Slipstream launcher or server, and probes `/health` and `/ready`. A server started from
  a terminal is found the same way and is shown as "started elsewhere".
- **Start.** Runs `<checkout>/slipstream serve --model … --port … [options]` in its own
  session with output to `~/Library/Logs/Slipstream/server.log` (the previous log is kept
  as `server.log.1`). While a GGUF model is being prepared, the status shows the
  converter's progress from the log.
- **Stop.** SIGTERM, then SIGKILL if the server is still running after 30 seconds.
  Force Stop sends SIGKILL right away.
- **Quit** leaves the server running; the next launch picks it up again.
- **Stats.** `/metrics` once a second while the panel or menu is open, every three
  seconds otherwise, plus `/status` every 15 seconds for the context limit. Token rates
  are counter deltas over a three-second wall-clock window. The engine's own
  `*_tokens_per_second` gauges divide by GPU step time and read far higher than what
  clients receive.
- **System.** CPU from per-core tick counters, GPU utilization from the accelerator's
  IOKit `PerformanceStatistics`, memory from `vm_statistics64`, swap from
  `vm.swapusage`: public APIs only, no helper or entitlements.

## Settings

| Setting | Passed as |
|---|---|
| Slipstream checkout | where `slipstream` is run from |
| Model | `--model` (GGUF folder, prepared package, or Hub repo id) |
| Port | `--port` |
| Max context | `--max-context` (empty = auto) |
| Max memory | `--max-memory` (empty = auto) |
| API key | `SLIPSTREAM_V2_API_KEY` in the server's environment; also sent by the app to read `/metrics` |
| Listen on the network | `--host 0.0.0.0` (off: 127.0.0.1 only); needs a launcher with `serve --host` ([npanj/slipstream#5](https://github.com/npanj/slipstream/pull/5)) |
| Allowed hosts | `--allowed-host`, repeated: extra names clients may use, such as `<mac>.local` |
| Disable web UI | `--no-webui` |
| Start the server when the app launches | only if none is running already |
| Open at login | a login item via `SMAppService` (needs the app in /Applications) |

With the network option on, other machines connect to `http://<this Mac's IP>:<port>`;
Settings lists the addresses and warns while no API key is set. Traffic is plain HTTP.

Changes take effect when the server restarts; Settings offers Save & Restart while one
is running.

## Layout

```
Sources/SlipstreamMenubarCore/   metrics parsing, rates, status logic, config, system sampling
Sources/SlipstreamMenubar/       AppKit menu, server control, SwiftUI panel and settings
Tests/SlipstreamMenubarCoreTests/
scripts/build-app.sh             assembles and signs the .app bundle
```

`--snapshot <file.png>` renders the panel to an image 45 seconds after launch, for
checking the layout without screen-recording permission.
