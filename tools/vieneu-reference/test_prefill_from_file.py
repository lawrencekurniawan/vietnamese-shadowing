from pathlib import Path

import numpy as np
import onnxruntime as ort


ROOT = Path(
    "/Users/lawrencewong/Movies/vietnamese_shadowing"
)

MODEL = (
    ROOT
    / "assets"
    / "vieneu"
    / "model"
    / "vieneu_prefill.onnx"
)

RUST_INPUT = (
    ROOT
    / "native"
    / "vieneu_core"
    / "rust_prefill_input.f32"
)

OUTPUT_DIR = (
    ROOT
    / "tools"
    / "vieneu-reference"
    / "python_from_rust_input"
)

OUTPUT_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


def main():
    data = np.fromfile(
        RUST_INPUT,
        dtype="<f4",
    )

    expected = 1 * 67 * 768

    print("Input values:", data.size)

    if data.size != expected:
        raise RuntimeError(
            f"Expected {expected} values, got {data.size}"
        )

    # IMPORTANT:
    # reshape without changing the float32 values.
    inputs = data.reshape(
        (1, 67, 768)
    ).astype(
        np.float32,
        copy=False,
    )

    print("Input shape:", inputs.shape)
    print("Input first 10:")
    print(inputs.reshape(-1)[:10])

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
        str(MODEL),
        so,
        providers=[
            "CPUExecutionProvider"
        ],
    )

    outputs = session.run(
        None,
        {
            "inputs_embeds": inputs,
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
        output = np.asarray(
            output,
            dtype=np.float32,
        )

        filename = (
            OUTPUT_DIR
            / f"python_from_rust_{index:02}.f32"
        )

        output.astype(
            "<f4",
            copy=False,
        ).tofile(filename)

        print(
            f"{index:02} {name}: "
            f"shape={output.shape}, "
            f"first5={output.reshape(-1)[:5]}"
        )


if __name__ == "__main__":
    main()