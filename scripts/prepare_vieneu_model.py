#!/usr/bin/env python3
"""Prepare the pinned FP32 VieNeu model assets required by Vietnamese Shadowing."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

REPO_ID = "pnnbao-ump/VieNeu-TTS-v3-Turbo"
# Pinned revision that restores the FP32 onnx_update weights used in local testing.
REVISION = "8b7e9cffb4b41918cb638b9f62f0a751184d14a6"
SOURCE_DIR = "onnx_update"
RUNTIME_FILES = (
    "config.json",
    "tokenizer.json",
    "vieneu_acoustic_cached.onnx",
    "vieneu_backbone_shared.data",
    "vieneu_decode_step.onnx",
    "vieneu_prefill.onnx",
)
NPZ_NAME = "vieneu_v3_heads.npz"
HEAD_NAMES = ("text_emb", "audio_emb", "xvec_w", "xvec_b", "xvec_ln_w", "xvec_ln_b")
EXPECTED_SHAPES = {
    "text_emb": (419, 768),
    "audio_emb": (16, 1024, 768),
    "xvec_w": (768, 192),
    "xvec_b": (768,),
    "xvec_ln_w": (768,),
    "xvec_ln_b": (768,),
}
EXPECTED_SIZES = {
    "vieneu_acoustic_cached.onnx": 7_207_223,
    "vieneu_backbone_shared.data": 415_319_040,
    "vieneu_decode_step.onnx": 306_134,
    "vieneu_prefill.onnx": 324_499,
}


def repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def model_is_ready(model_dir: Path) -> bool:
    try:
        config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
        if config.get("dtype") != "float32":
            return False
        if int(config.get("max_position_embeddings", 0)) != 2048:
            return False
        if not (model_dir / "tokenizer.json").is_file():
            return False
        if not (model_dir / "vieneu_heads.json").is_file():
            return False
        if (model_dir / "vieneu_heads.json").stat().st_size < 150_000_000:
            return False
        for name, expected in EXPECTED_SIZES.items():
            file = model_dir / name
            if not file.is_file() or file.stat().st_size != expected:
                return False
        return True
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return False


def copy_or_hardlink(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".prepare-tmp")
    temporary.unlink(missing_ok=True)
    try:
        # Hugging Face snapshots normally point to cached blobs. A hard link
        # avoids duplicating hundreds of MB when both paths share a filesystem.
        os.link(source.resolve(), temporary)
    except OSError:
        shutil.copy2(source, temporary)
    os.replace(temporary, destination)


def write_flat_heads(npz_path: Path, output_path: Path) -> None:
    import numpy as np

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(output_path.name + ".prepare-tmp")
    temporary.unlink(missing_ok=True)

    with np.load(npz_path, allow_pickle=False) as archive, temporary.open("w", encoding="utf-8") as out:
        missing = [name for name in (*HEAD_NAMES, "xvec_ln_eps") if name not in archive]
        if missing:
            raise RuntimeError(f"The downloaded heads NPZ is missing: {', '.join(missing)}")

        out.write("{")
        for index, name in enumerate(HEAD_NAMES):
            array = np.asarray(archive[name], dtype=np.float32)
            expected = EXPECTED_SHAPES[name]
            if array.shape != expected:
                raise RuntimeError(f"Unexpected {name} shape {array.shape}; expected {expected}")
            if not np.isfinite(array).all():
                raise RuntimeError(f"The {name} array contains non-finite values")

            if index:
                out.write(",")
            out.write(json.dumps(name) + ":{\"shape\":")
            json.dump(list(array.shape), out, separators=(",", ":"))
            out.write(',"data":[')
            flat = array.reshape(-1)
            chunk_size = 50_000
            for start in range(0, flat.size, chunk_size):
                if start:
                    out.write(",")
                chunk = json.dumps(
                    flat[start : start + chunk_size].tolist(),
                    separators=(",", ":"),
                    allow_nan=False,
                )
                out.write(chunk[1:-1])
            out.write("]}")

        epsilon = float(archive["xvec_ln_eps"])
        if not np.isfinite(epsilon):
            raise RuntimeError("xvec_ln_eps contains a non-finite value")
        out.write(',"xvec_ln_eps":')
        json.dump(epsilon, out, allow_nan=False)
        out.write("}\n")

    os.replace(temporary, output_path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--force",
        action="store_true",
        help="Download/prepare again even if the expected FP32 assets already exist.",
    )
    args = parser.parse_args()

    root = repository_root()
    model_dir = root / "assets" / "vieneu" / "model"
    if not args.force and model_is_ready(model_dir):
        # The NPZ is a source archive used to create heads.json, not a runtime
        # asset. Keep it out of the Flutter bundle when it is left over locally.
        (model_dir / NPZ_NAME).unlink(missing_ok=True)
        print(f"FP32 VieNeu runtime assets already look ready: {model_dir}")
        print("Removed redundant NPZ from the runtime asset folder, if present.")
        print("Use --force to re-download the pinned source revision.")
        return 0

    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        print(
            "Missing setup dependencies. Run:\n"
            "  uv run --with huggingface_hub --with numpy python scripts/prepare_vieneu_model.py",
            file=sys.stderr,
        )
        return 2

    allowed = [f"{SOURCE_DIR}/{name}" for name in (*RUNTIME_FILES, NPZ_NAME)]
    print(f"Downloading pinned FP32 model {REPO_ID}@{REVISION}")
    snapshot = Path(
        snapshot_download(
            repo_id=REPO_ID,
            revision=REVISION,
            allow_patterns=allowed,
        )
    )
    source_dir = snapshot / SOURCE_DIR
    missing = [name for name in (*RUNTIME_FILES, NPZ_NAME) if not (source_dir / name).is_file()]
    if missing:
        raise RuntimeError(f"The pinned source snapshot is missing: {', '.join(missing)}")

    for name, expected in EXPECTED_SIZES.items():
        actual = (source_dir / name).stat().st_size
        if actual != expected:
            raise RuntimeError(f"Unexpected {name} size {actual}; expected {expected}")

    model_dir.mkdir(parents=True, exist_ok=True)
    # Generate this custom Rust-consumed file from the upstream NPZ. The NPZ
    # itself stays in Hugging Face's cache rather than being bundled in the app.
    print("Converting the NPZ heads to the flat JSON format expected by Rust...")
    write_flat_heads(source_dir / NPZ_NAME, model_dir / "vieneu_heads.json")

    for name in RUNTIME_FILES:
        print(f"Preparing {name}")
        copy_or_hardlink(source_dir / name, model_dir / name)

    # Older checkouts tracked this source archive inside the Flutter assets
    # folder; it is only needed to produce vieneu_heads.json, not at runtime.
    (model_dir / NPZ_NAME).unlink(missing_ok=True)

    if not model_is_ready(model_dir):
        raise RuntimeError("Model files were prepared, but final validation failed")

    print("\nVieNeu FP32 model assets are ready.")
    print("Pinned source revision:", REVISION)
    print("App runtime assets:", model_dir)
    print("The model will be bundled into the app at its next Flutter build.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Model preparation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
