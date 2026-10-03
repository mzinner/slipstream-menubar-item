# Slipstream: the server contract and the related repos

Part of the project context; see [the index](../PROJECT_CONTEXT.md).

## Slipstream server contract (what the app relies on)

- **Launch chain:** `./slipstream serve …` → `slipstream-v2` (sh) → `.venv/bin/python
  install/launcher.py`. The launcher takes an `flock` on `build/runtime/serve.lock`, writes `{"pid",
  "model", "port", "host"}` (`host` only with PR #5), and probes `bind((host, port))`. For a GGUF
  folder without `prepared/manifest.json` + `prepared/target/layer-0.bin`, it runs the converter as a
  subprocess. Then it `os.execve`s into `server/server.py` (same pid), which starts the engine
  (`build/slipstream-v2 serve-native`) as a child. The lock keeps its contents after exit.
  `--max-context`/`--max-memory` default to `auto` (256K context here).
- **Hub ids (26.10.3+):** `serve --model <owner/repo>` and `pull <owner/repo>` run
  `install/models.py prepare` into the model store (`~/.slipstream/models`, `SLIPSTREAM_MODELS`).
  A GGUF repository becomes a real folder `<store>/<owner>/<repo>` with `.slipstream-gguf.json`
  (`model`, pinned `revision`, `"downloaded": true` when complete), the shards, and
  `MTP/mtp-shared-Q4_K_M.gguf` (from `nitinpanj/qwen38-flash-next-v3@e2982050…` when the repository
  lacks it); `serve` then prepares `prepared/` there, and serves under the Hub id as model name. A
  package stays a link into the Hub cache.
- **In-place preparation (26.10.4+):** for a store install, `serve` runs the converter with
  `--consume-source`: each GGUF tensor's bytes are freed (`F_PUNCHHOLE`) once its part is written,
  then the shards and MTP head are deleted. Peak 102.6 GiB vs 197 before, output byte-identical.
  `serve --keep-gguf` keeps them; a user's own folder is never used up; an already prepared store
  model loses its leftover shards on the next serve (~191 GB on this Mac once 26.10.4 runs here).
  Resumable (`prepared/.prepare-journal`, parts renamed from `.partial` when complete).
- **`pull <repo> --check [--json]` (26.10.4+):** downloads nothing; `{"supported": true, "kind",
  "bytes", "revision", "files", "mtp"}` or `{"supported": false, "reason"}`, exit 0/1. GGUF must be
  one model (single file or one complete split set) of architecture `qwen4exp` (256 KiB ranged
  header read); packages go through `validate_package_manifest`. Plain `pull` refuses the same
  before writing anything. Uses the bundled `huggingface_hub` 1.28 and its token. `pull` `exec`s the download: SIGINT exits 130 after files
  in transfer finish (21 s once) and the next pull resumes. Done downloads skip the network.
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

## Related repos

- `~/git/slipstream`: Slipstream checkout. On `main`, which tracks the fork `mzinner/slipstream`:
  upstream plus PRs #3 (issue #1 fixes), #4 (GGUF conversion without reference, memory caps) and #5
  (`serve --host`) as a linear stack, then the fork's own commits (release workflow, converter
  folder fix, v2-only packages, Hub-id install, `pull`). Remotes: `upstream` (npanj), `mzinner` (fork), `fork`
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
  - **Splash 1.0 packages refused** (`923c9fa` on `main`; alone on `fix/v2-only-packages`,
    `b2d9640`, based on `upstream/main`, for a later PR): `validate_package_manifest` refuses
    `splash-packed-q4[-moe]` from the manifest, `official-models.txt` is empty, `COLLECTION = None`
    (no refresh is spawned; `update_model_catalog.py` exits 0). 60 tests pass;
    `test_package`'s `engine/splash` path assertion already fails on upstream (binary renamed).
  - **Verified on this Mac:** the app's installer installed it into `~/.local`, and it serves the
    prepared model correctly (17 × 23 = 391, "Tokyo").
- **Hub-id install and `pull` (2026-10-03, fork v26.10.3, `main` up to `18815d8`):**
  - `serve --model <GGUF repo>` used to fail ("no … manifest.json"); now it downloads the shards and
    the MTP head the repository lacks (the Swift repository has none), checks disk for shards plus
    prepared copy, then converts. `slipstream pull` does the download alone (for this app).
  - The model store moved out of the checkout / Application Support to `~/.slipstream/models`
    for source and release installs alike (user's choice, like oMLX's `~/.omlx/models`); excluded
    from Time Machine on creation. Completion and `MODEL_ROOT` follow; `ci.yml`'s `clean: false`
    comment says so.
  - Measured on Swift V3 from a fresh download: prepared in 215 s, 42.0 tok/s decode with the
    fetched MTP head (72 % acceptance) vs 20.0 tok/s with `SPLASH_NO_MTP=1`.
  - Upstream-ready, pushed to `mzinner`, no PR yet: `feat/gguf-hub-install` (stacked on
    `fix/converter-own-folder`) and `feat/slipstream-pull` (stacked on it). Open them after #3/#4,
    from the `fork` remote like #3–#5.
  - `make check-source` fails on `main` over whitespace in `.agents/*`, `docs/research/…` and two
    `dev/tools` scripts, all older than this work.
- **Low-disk preparation and `pull --check` (2026-10-03, fork v26.10.4, `main` up to `9ada146`):**
  - Upstream-ready branches, pushed to `mzinner`, no PR yet, stacked:
    `feat/slipstream-pull` → `feat/gguf-low-disk-prepare` (2 commits) → `feat/pull-check` (1).
    Cherry-picked onto `main` (the fork's `main` holds its own linear copy of the stack, so a merge
    would duplicate commits). The check test avoids depending on the fork-only Splash 1.0 refusal.
  - Python tests: 93 in the touched suites; the full suite has 43 failures that exist without
    these changes too (engine-dependent).
  - Release notes in the fork's workflow now describe in-place preparation and `--check`.
  - Verified: the released 26.10.4 package has `--keep-gguf` and answers `--check`.
- **Hugging Face (account MikeZ75, logged in with `hf`):** the two prepared packages are public:
  `MikeZ75/Swift-Qwen3.8-Flash-Next-V3-Splash` and `MikeZ75/Qwen3.8-Flash-Next-V3-Splash`
  (107,723,711,614 bytes each, 67 files; license `other` Qwen Community, as the sources; cards
  credit UkisAI, nitinpanj, Qwen). Staged with `scripts/stage-hub-package.py` (hard links, adds
  `target/draft-vocab.bin` from `nitinpanj/Swift-Qwen3.8-Flash-Next-Splash`, which the installer
  requires and the converter doesn't write, the manifest's artifact list and `config.json`), then
  `hf upload-large-folder`. The Swift one went in ~10 min (Xet already had ~76 GB of it from the
  author's unfinished `nitinpanj/Swift-Qwen3.8-Flash-Next-Splash`), the base one ~30 min at
  ~600 Mbit/s. The Swift one was pulled from the Hub, passed `verify --full`, and served
  correctly (17 × 23 = 391, ~32 tok/s); the base one only passed `--check`.
