from pathlib import Path
import json

import numpy as np

from vieneu._v3_turbo_engine.onnx_runtime_lite import OnnxV3LiteEngine
from vieneu_utils.phonemize_text import phonemize_text_with_emotions


ROOT = Path("/Users/lawrencewong/Movies/vietnamese_shadowing")

MODEL_DIR = ROOT / "assets/vieneu/model"
CODEC_DIR = ROOT / "assets/vieneu/codec"
VOICES = ROOT / "assets/vieneu/voices_v3_turbo.json"

OUTPUT_DIR = ROOT / "tools/vieneu-reference"


def main():
    engine = OnnxV3LiteEngine(
        onnx_dir=str(MODEL_DIR),
        codec_dir=str(CODEC_DIR),
    )

    with VOICES.open("r", encoding="utf-8") as f:
        voices = json.load(f)

    voice = voices["presets"]["Xuân Vĩnh"]

    speaker_emb = np.asarray(
        voice["speaker_emb"],
        dtype=np.float32,
    )

    ref_codes = np.asarray(
        voice["codes"],
        dtype=np.int64,
    )

    text = "Hôm nay bạn khỏe không?"

    phonemes = phonemize_text_with_emotions(text)

    # ---------------------------------------------------------
    # Speaker anchor diagnostics
    # ---------------------------------------------------------

    v = np.asarray(
        speaker_emb,
        dtype=np.float32,
    ).reshape(-1)

    projected = (
        v @ engine.xvec_w.T
        + engine.xvec_b
    )

    anchor_mean = projected.mean()

    anchor_var = projected.var()

    normalized = (
        (projected - anchor_mean)
        / np.sqrt(
            anchor_var + engine.xvec_ln_eps
        )
    )

    anchor = (
        normalized * engine.xvec_ln_w
        + engine.xvec_ln_b
    ).astype(np.float32)

    projected.astype(
        "<f4",
        copy=False,
    ).tofile(
        OUTPUT_DIR / "python_anchor_projected.f32"
    )

    np.asarray(
        [anchor_mean],
        dtype="<f4",
    ).tofile(
        OUTPUT_DIR / "python_anchor_mean.f32"
    )

    np.asarray(
        [anchor_var],
        dtype="<f4",
    ).tofile(
        OUTPUT_DIR / "python_anchor_var.f32"
    )

    normalized.astype(
        "<f4",
        copy=False,
    ).tofile(
        OUTPUT_DIR / "python_anchor_normalized.f32"
    )

    anchor.astype(
        "<f4",
        copy=False,
    ).tofile(
        OUTPUT_DIR / "python_anchor.f32"
    )

    speaker_emb.astype(
        "<f4",
        copy=False,
    ).tofile(
        OUTPUT_DIR / "python_speaker_emb.f32"
    )

    engine.xvec_w.astype(
        "<f4",
        copy=False,
    ).tofile(
        OUTPUT_DIR / "python_xvec_w.f32"
    )

    engine.xvec_b.astype(
        "<f4",
        copy=False,
    ).tofile(
        OUTPUT_DIR / "python_xvec_b.f32"
    )

    rows = engine._build_rows(
        phonemes,
        ref_codes,
        engine._resolve_style_id(),
    )

    # ---------------------------------------------------------
    # Stage 1: text only
    # ---------------------------------------------------------

    text_only = engine.text_emb[
        rows[:, 0]
    ].copy()

    # ---------------------------------------------------------
    # Stage 2: text + audio
    # ---------------------------------------------------------

    text_audio = text_only.copy()

    for ch in range(engine.n_vq):
        ids = rows[:, ch + 1]

        valid = ids != engine.audio_pad

        safe = np.where(
            valid,
            ids,
            0,
        )

        text_audio = (
            text_audio
            + engine.audio_emb[ch][safe]
            * valid[:, None]
        )

    # ---------------------------------------------------------
    # Stage 3: text + audio + speaker anchor
    # ---------------------------------------------------------

    full = text_audio + anchor[None]

    text_only.astype("<f4", copy=False).tofile(
        OUTPUT_DIR / "python_text_only.f32"
    )

    text_audio.astype("<f4", copy=False).tofile(
        OUTPUT_DIR / "python_text_audio.f32"
    )

    full.astype("<f4", copy=False).tofile(
        OUTPUT_DIR / "python_full.f32"
    )

    print("text_only:", text_only.shape)
    print("text_audio:", text_audio.shape)
    print("full:", full.shape)

    print()
    print("Saved:")
    print(OUTPUT_DIR / "python_text_only.f32")
    print(OUTPUT_DIR / "python_text_audio.f32")
    print(OUTPUT_DIR / "python_full.f32")


if __name__ == "__main__":
    main()