import json
from pathlib import Path

import numpy as np

from vieneu._v3_turbo_engine.onnx_runtime_lite import OnnxV3LiteEngine
from vieneu_utils.phonemize_text import phonemize_text_with_emotions


PROJECT_ROOT = Path(__file__).resolve().parents[2]

MODEL_DIR = (
    PROJECT_ROOT
    / "assets"
    / "vieneu"
    / "model"
)

CODEC_DIR = (
    PROJECT_ROOT
    / "assets"
    / "vieneu"
    / "codec"
)

VOICES_FILE = (
    PROJECT_ROOT
    / "assets"
    / "vieneu"
    / "voices_v3_turbo.json"
)


def main() -> None:
    text = "Hôm nay bạn khỏe không?"
    voice_name = "Xuân Vĩnh"

    print("=== Paths ===")
    print("Model :", MODEL_DIR)
    print("Codec :", CODEC_DIR)
    print("Voices:", VOICES_FILE)
    print()

    print("=== Loading VieNeu ONNX engine ===")

    engine = OnnxV3LiteEngine(
        onnx_dir=str(MODEL_DIR),
        codec_dir=str(CODEC_DIR),
    )

    print("Engine loaded.")
    print()

    # ---------------------------------------------------------
    # Load preset voice
    # ---------------------------------------------------------

    with VOICES_FILE.open(
        "r",
        encoding="utf-8",
    ) as f:
        voices = json.load(f)

    preset = voices["presets"][voice_name]

    speaker_emb = np.asarray(
        preset["speaker_emb"],
        dtype=np.float32,
    )

    ref_codes = np.asarray(
        preset["codes"],
        dtype=np.int64,
    )

    print("=== Voice ===")
    print("Name:", voice_name)
    print("Description:", preset["description"])
    print("Gender:", preset["gender"])
    print("Region:", preset.get("region"))
    print("Style:", preset.get("style"))
    print("speaker_emb shape:", speaker_emb.shape)
    print("ref_codes shape:", ref_codes.shape)
    print()

    # ---------------------------------------------------------
    # Vietnamese phonemization
    # ---------------------------------------------------------

    phonemes = phonemize_text_with_emotions(text)

    print("=== Text ===")
    print(text)
    print()

    print("=== SEA-G2P ===")
    print(phonemes)
    print()

    # ---------------------------------------------------------
    # Speaker anchor
    # ---------------------------------------------------------

    anchor = engine._speaker_anchor(
        speaker_emb
    )

    print("=== Speaker anchor ===")
    print("shape:", anchor.shape)
    print("dtype:", anchor.dtype)
    print()

    # ---------------------------------------------------------
    # Build prompt rows
    # ---------------------------------------------------------

    style_id = engine._resolve_style_id()

    rows = engine._build_rows(
        phonemes,
        ref_codes,
        style_id,
    )

    print("=== Prompt rows ===")
    print("shape:", rows.shape)
    print("dtype:", rows.dtype)
    print()

    print("First 10 rows:")
    print(rows[:10])
    print()

    print("Last 5 rows:")
    print(rows[-5:])
    print()

    # ---------------------------------------------------------
    # Convert rows into transformer embeddings
    # ---------------------------------------------------------

    prompt_embeds = engine._embed_rows(
        rows,
        anchor,
    )

    print("=== Prompt embeddings ===")
    print("shape:", prompt_embeds.shape)
    print("dtype:", prompt_embeds.dtype)
    print()

    # ---------------------------------------------------------
    # Run VieNeu prefill
    # ---------------------------------------------------------

    print("=== Prefill ===")

    pre = engine.sess_pre.run(
        None,
        {
            "inputs_embeds": prompt_embeds,
        },
    )

    print("Number of outputs:", len(pre))

    for i, value in enumerate(pre):
        print(
            f"output[{i:02d}] "
            f"shape={value.shape} "
            f"dtype={value.dtype}"
        )

    print()

    # ---------------------------------------------------------
    # Extract hidden state + transformer KV cache
    # ---------------------------------------------------------

    h = pre[0][:, -1]

    past_k = [
        pre[1 + i]
        for i in range(engine.L)
    ]

    past_v = [
        pre[1 + engine.L + i]
        for i in range(engine.L)
    ]

    print("=== Prefill result ===")
    print("h shape:", h.shape)

    print(
        "past_k layers:",
        len(past_k),
    )

    print(
        "past_v layers:",
        len(past_v),
    )

    for i in range(
        min(2, len(past_k))
    ):
        print(
            f"past_k_{i}:",
            past_k[i].shape,
        )
        print(
            f"past_v_{i}:",
            past_v[i].shape,
        )

    print()

    # ---------------------------------------------------------
    # Generate ONE acoustic frame
    # ---------------------------------------------------------

    print("=== One acoustic frame ===")

    codes, eos = engine._acoustic_frame(
        h,
        temperature=0.8,
        top_k=25,
        top_p=0.95,
        rep_pen=1.2,
        hist=None,
    )

    print("codes:", codes)
    print("number of codes:", len(codes))
    print("EOS:", eos)
    print()

    print("=== SUCCESS ===")
    print(
        "VieNeu prefill + one acoustic frame "
        "executed successfully."
    )


if __name__ == "__main__":
    main()