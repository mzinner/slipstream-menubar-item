#!/usr/bin/env python3
"""Stage a prepared Slipstream package for a Hugging Face upload, without copying it.

    scripts/stage-hub-package.py <prepared dir> <staging dir> <draft-vocab.bin>

<prepared dir> is a model's `prepared/` folder in Slipstream's model store, e.g.
~/.slipstream/models/nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF/prepared.
The staging dir must be on the same volume: every package file is hard-linked
into it (no extra disk), so delete it, not the prepared folder, when done.

It adds what a package on the Hub needs beyond what Slipstream prepares locally:
- target/draft-vocab.bin, which the GGUF converter does not write but the
  installer requires: a ranking of the vocabulary that only affects drafting
  speed. Both Qwen3.8-Flash-Next models share the vocabulary, so one file fits
  both: `hf download nitinpanj/Swift-Qwen3.8-Flash-Next-Splash target/draft-vocab.bin`.
- manifest.json with the artifact list (path, size, sha256) that `slipstream
  pull` verifies every download against, checked with Slipstream's own
  validate_package_manifest.
- config.json, the Hub's metadata for the format.

Then write README.md (the model card: license and base_model as in the source
GGUF's card, credit to its authors) and upload:

    hf repos create <owner>/<name> --repo-type model
    hf upload-large-folder <owner>/<name> <staging dir> --repo-type model
    slipstream pull <owner>/<name> --check

SLIPSTREAM_CHECKOUT names the Slipstream checkout (default ~/git/slipstream),
whose install/models.py holds the validation.
"""

import concurrent.futures
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

CHECKOUT = Path(os.environ.get("SLIPSTREAM_CHECKOUT", "~/git/slipstream")).expanduser()
sys.path.insert(0, str(CHECKOUT / "install"))
import models as installer  # noqa: E402

CONFIG = {
    "architectures": ["Qwen4ExpForCausalLM"],
    "model_type": "splash-packed-q4-qwen4exp",
    "format": "splash-packed-q4-qwen4exp",
    "schema_version": 5,
    "quantization_config": {"quant_method": "tiled-q4-q8", "bits": 4, "group_size": 64},
    "speculative": {"method": "mtp-ngram", "proposal_tokens": 7},
    "runtime": "https://github.com/npanj/slipstream",
    "package_manifest": "manifest.json",
}


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(16 << 20):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    source, stage, vocab = (Path(a).expanduser() for a in sys.argv[1:4])
    if not (source / "manifest.json").is_file():
        sys.exit(f"{source} is not a prepared package (no manifest.json)")
    stage.mkdir(parents=True, exist_ok=True)

    files = sorted(p for p in source.rglob("*")
                   if p.is_file() and p.name != "manifest.json" and not p.name.startswith("."))
    for path in files:
        link = stage / path.relative_to(source)
        link.parent.mkdir(parents=True, exist_ok=True)
        if not link.exists():
            os.link(path, link)
    if not (stage / "target/draft-vocab.bin").exists():
        shutil.copyfile(vocab, stage / "target/draft-vocab.bin")

    artifacts = sorted(p for p in stage.rglob("*") if p.is_file() and p.parent != stage)
    with concurrent.futures.ProcessPoolExecutor(8) as pool:
        digests = dict(zip(artifacts, pool.map(digest, artifacts)))
    manifest = json.loads((source / "manifest.json").read_text())
    manifest["artifacts"] = [{"path": p.relative_to(stage).as_posix(), "size": p.stat().st_size,
                              "sha256": digests[p]} for p in artifacts]
    (stage / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    (stage / "config.json").write_text(json.dumps(CONFIG, indent=2) + "\n")

    checked = installer.validate_package_manifest(stage / "manifest.json")
    installer.verify_artifacts(stage, checked, full=False)
    total = sum(r["size"] for r in manifest["artifacts"])
    print(f"{len(manifest['artifacts'])} artifacts, {total / 2**30:.2f} GiB ({total} bytes); "
          f"manifest valid: {checked['model']}. Write README.md, then upload {stage}.")


if __name__ == "__main__":
    main()
