from pathlib import Path
import json

import numpy as np

from vieneu._v3_turbo_engine.onnx_runtime_lite import OnnxV3LiteEngine


ROOT = Path("/Users/lawrencewong/Movies/vietnamese_shadowing")

MODEL_DIR = ROOT / "assets/vieneu/model"
CODEC_DIR = ROOT / "assets/vieneu/codec"
VOICES = ROOT / "assets/vieneu/voices_v3_turbo.json"


def main():
    engine = OnnxV3LiteEngine(
        onnx_dir=str(MODEL_DIR),
        codec_dir=str(CODEC_DIR),
    )

    with VOICES.open("r", encoding="utf-8") as f:
        voices = json.load(f)

    speaker = np.asarray(
        voices["presets"]["Xuân Vĩnh"]["speaker_emb"],
        dtype=np.float32,
    )

    w = np.asarray(
        engine.xvec_w,
        dtype=np.float32,
    )

    b = np.asarray(
        engine.xvec_b,
        dtype=np.float32,
    )

    # Python / NumPy reference.
    numpy_projection = (
        speaker @ w.T + b
    ).astype(np.float32)

    # Same scalar order as Rust f32.
    rust_f32 = np.empty(
        768,
        dtype=np.float32,
    )

    for i in range(768):
        value = b[i]

        for j in range(192):
            value = np.float32(
                value
                + np.float32(
                    w[i, j] * speaker[j]
                )
            )

        rust_f32[i] = value

    # Same scalar order as Rust f64.
    rust_f64 = np.empty(
        768,
        dtype=np.float32,
    )

    for i in range(768):
        value = float(b[i])

        for j in range(192):
            value += (
                float(w[i, j])
                * float(speaker[j])
            )

        rust_f64[i] = np.float32(value)

    # Compare.
    for name, x in [
        ("scalar f32", rust_f32),
        ("scalar f64", rust_f64),
    ]:
        d = np.abs(
            numpy_projection.astype(np.float64)
            - x.astype(np.float64)
        )

        print(
            f"{name:12s} "
            f"max={d.max():.9e} "
            f"mean={d.mean():.9e}"
        )


if __name__ == "__main__":
    main()