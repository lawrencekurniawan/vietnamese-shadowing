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

OUTPUT_DIR = ROOT / "tools/vieneu-reference/python_prefill"


def main() -> None:
    OUTPUT_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    text = "Hôm nay bạn khỏe không?"
    voice_name = "Xuân Vĩnh"

    print("Loading VieNeu engine...")

    engine = OnnxV3LiteEngine(
        onnx_dir=str(MODEL_DIR),
        codec_dir=str(CODEC_DIR),
    )

    print("Loading voice...")

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

    print("Phonemizing...")

    phonemes = phonemize_text_with_emotions(text)

    print("Phonemes:")
    print(phonemes)

    print("Building prompt...")

    anchor = engine._speaker_anchor(
        speaker_emb
    )

    rows = engine._build_rows(
        phonemes,
        ref_codes,
        engine._resolve_style_id(),
    )

    print("Prompt rows:", rows.shape)

    prompt_embeds = engine._embed_rows(
        rows,
        anchor,
    )

    input_path = (
        OUTPUT_DIR
        / "python_prefill_input.f32"
    )

    prompt_embeds.astype(
        "<f4",
        copy=False,
    ).tofile(input_path)

    print(
        "Saved:",
        input_path,
    )

    print(
        "Prompt embeddings:",
        prompt_embeds.shape,
    )

    print("Running prefill...")

    outputs = engine.sess_pre.run(
        None,
        {
            "inputs_embeds": prompt_embeds,
        },
    )

    names = (
        ["hidden"]
        + [
            f"present_k_{i}"
            for i in range(12)
        ]
        + [
            f"present_v_{i}"
            for i in range(12)
        ]
    )

    if len(outputs) != len(names):
        raise RuntimeError(
            f"Expected {len(names)} outputs, "
            f"got {len(outputs)}"
        )

    for index, (name, output) in enumerate(
        zip(names, outputs)
    ):
        array = np.asarray(
            output,
            dtype=np.float32,
        )

        filename = (
            OUTPUT_DIR
            / f"python_prefill_{index:02}.f32"
        )

        # Save exact float32 bytes in little-endian
        # format, matching the Rust test.
        array.astype(
            "<f4",
            copy=False,
        ).tofile(filename)

        print(
            f"{index:02} {name}: "
            f"shape={array.shape}, "
            f"values={array.size}"
        )

        print(
            "  first 5:",
            array.reshape(-1)[:5],
        )

        print(
            "  saved:",
            filename,
        )

    print()
    print(
        f"Saved {len(outputs)} tensors to:"
    )
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()