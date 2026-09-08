from pathlib import Path

import numpy as np
import onnxruntime as ort


ROOT = Path("/Users/lawrencewong/Movies/vietnamese_shadowing")

MODEL = (
    ROOT
    / "assets/vieneu/model/vieneu_prefill.onnx"
)

INPUT = (
    ROOT
    / "native/vieneu_core/rust_prefill_input.f32"
)

OUTPUT_DIR = (
    ROOT
    / "tools/vieneu-reference/direct_prefill"
)

OUTPUT_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


def main():
    x = np.fromfile(
        INPUT,
        dtype="<f4",
    ).reshape(1, 67, 768)

    print("ORT:", ort.__version__)
    print("Input shape:", x.shape)
    print("Input first 10:")
    print(x.reshape(-1)[:10])

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
        providers=["CPUExecutionProvider"],
    )

    print()
    print("Providers:", session.get_providers())
    print("Provider options:", session.get_provider_options())

    outputs = session.run(
        None,
        {
            "inputs_embeds": x,
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

        path = (
            OUTPUT_DIR
            / f"python_direct_{index:02d}.f32"
        )

        array.astype(
            "<f4",
            copy=False,
        ).tofile(path)

        print(
            f"{index:02d} {name}: "
            f"shape={array.shape}, "
            f"first5={array.reshape(-1)[:5]}"
        )


if __name__ == "__main__":
    main()