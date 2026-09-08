import json
from pathlib import Path

import numpy as np
import onnxruntime as ort

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

OUTPUT_DIR = ROOT / "tools/vieneu-reference/python_prefill_noopt"
OUTPUT_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


def main():
    # We use VieNeu only for preprocessing.
    engine = OnnxV3LiteEngine(
        onnx_dir=str(MODEL_DIR),
        codec_dir=str(CODEC_DIR),
    )

    with VOICES.open(
        "r",
        encoding="utf-8",
    ) as f:
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

    so = ort.SessionOptions()

    so.graph_optimization_level = (
        ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    )

    so.inter_op_num_threads = 1
    so.intra_op_num_threads = 1

    so.add_session_config_entry(
        "session.intra_op.allow_spinning",
        "0",
    )

    session = ort.InferenceSession(
        str(MODEL_DIR / "vieneu_prefill.onnx"),
        so,
        providers=["CPUExecutionProvider"],
    )

    # Save the exact tensor passed to ONNX Runtime.
    prompt_embeds.astype(
        "<f4",
        copy=False,
    ).tofile(
        OUTPUT_DIR / "python_prefill_input.f32"
    )

    print(
        "Saved input:",
        OUTPUT_DIR / "python_prefill_input.f32",
    )

    outputs = session.run(
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

        array.astype(
            "<f4",
            copy=False,
        ).tofile(filename)

        print(
            f"{index:02} {name}: "
            f"shape={array.shape}"
        )


if __name__ == "__main__":
    main()