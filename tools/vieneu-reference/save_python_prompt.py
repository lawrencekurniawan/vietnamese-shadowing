from pathlib import Path
import json

import numpy as np

from vieneu._v3_turbo_engine.onnx_runtime_lite import (
    OnnxV3LiteEngine,
)
from vieneu_utils.phonemize_text import (
    phonemize_text_with_emotions,
)


ROOT = Path("/Users/lawrencewong/Movies/vietnamese_shadowing")

MODEL_DIR = ROOT / "assets/vieneu/model"
CODEC_DIR = ROOT / "assets/vieneu/codec"
VOICES = ROOT / "assets/vieneu/voices_v3_turbo.json"

OUTPUT = ROOT / "tools/vieneu-reference/python_prompt_embeddings.f32"


def main():
    text = "Hôm nay bạn khỏe không?"
    voice_name = "Xuân Vĩnh"

    engine = OnnxV3LiteEngine(
        onnx_dir=str(MODEL_DIR),
        codec_dir=str(CODEC_DIR),
    )

    with VOICES.open("r", encoding="utf-8") as f:
        voices = json.load(f)

    voice = voices["presets"][voice_name]

    speaker_emb = np.asarray(
        voice["speaker_emb"],
        dtype=np.float32,
    )

    ref_codes = np.asarray(
        voice["codes"],
        dtype=np.int64,
    )

    phonemes = phonemize_text_with_emotions(text)

    anchor = engine._speaker_anchor(
        speaker_emb
    )

    rows = engine._build_rows(
        phonemes,
        ref_codes,
        engine._resolve_style_id(),
    )

    prompt_embeds = engine._embed_rows(
        rows,
        anchor,
    )

    print("phonemes:")
    print(phonemes)

    print()
    print("rows shape:", rows.shape)

    print()
    print("prompt embeddings shape:", prompt_embeds.shape)

    print()
    print("first row, first 10:")
    print(prompt_embeds[0, 0, :10])

    prompt_embeds.astype(
        "<f4",
        copy=False,
    ).tofile(OUTPUT)

    print()
    print("saved:")
    print(OUTPUT)


if __name__ == "__main__":
    main()