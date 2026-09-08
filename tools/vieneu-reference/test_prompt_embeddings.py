import json
from pathlib import Path

import numpy as np

from vieneu._v3_turbo_engine.onnx_runtime_lite import (
    OnnxV3LiteEngine,
)
from vieneu_utils.phonemize_text import (
    phonemize_text_with_emotions,
)


ROOT = Path(__file__).resolve().parents[2]

MODEL_DIR = ROOT / "assets/vieneu/model"
CODEC_DIR = ROOT / "assets/vieneu/codec"
VOICES = ROOT / "assets/vieneu/voices_v3_turbo.json"
OUTPUT = ROOT / "tools/vieneu-reference/python_prompt_embeds.npy"


def main() -> None:
    text = "Hôm nay bạn khỏe không?"
    voice_name = "Xuân Vĩnh"

    engine = OnnxV3LiteEngine(
        onnx_dir=str(MODEL_DIR),
        codec_dir=str(CODEC_DIR),
    )

    with VOICES.open(
        "r",
        encoding="utf-8",
    ) as f:
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

    np.save(
        OUTPUT,
        prompt_embeds,
    )

    print("Phonemes:")
    print(phonemes)

    print()
    print("Rows:", rows.shape)

    print(
        "Prompt embeddings:",
        prompt_embeds.shape,
    )

    print(
        "dtype:",
        prompt_embeds.dtype,
    )

    print(
        "min:",
        prompt_embeds.min(),
    )

    print(
        "max:",
        prompt_embeds.max(),
    )

    print(
        "mean:",
        prompt_embeds.mean(),
    )

    print(
        "saved:",
        OUTPUT,
    )


if __name__ == "__main__":
    main()