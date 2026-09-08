from pathlib import Path

import numpy as np
import onnxruntime as ort


ROOT = Path("/Users/lawrencewong/Movies/vietnamese_shadowing")

MODEL = (
    ROOT
    / "assets/vieneu/model/vieneu_decode_step.onnx"
)

RUST_ROOT = (
    ROOT
    / "native/vieneu_core"
)

OUTPUT_DIR = (
    ROOT
    / "tools/vieneu-reference/direct_decode"
)

OUTPUT_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


N_LAYERS = 12
PROMPT_LENGTH = 67


def read_f32(path, count=None):
    x = np.fromfile(path, dtype="<f4")

    if count is not None and len(x) != count:
        raise RuntimeError(
            f"{path}: expected {count} values, got {len(x)}"
        )

    return x


def main():
    # ---------------------------------------------------------
    # Exact Rust decoder input
    # ---------------------------------------------------------

    x = read_f32(
        RUST_ROOT / "rust_decode_input.f32",
        768,
    ).reshape(1, 1, 768)

    print("Input shape:", x.shape)
    print("Input first 10:")
    print(x.reshape(-1)[:10])

    # ---------------------------------------------------------
    # Exact position used by Rust
    # First generated position = prompt length = 67
    # ---------------------------------------------------------

    position_ids = np.array(
        [[PROMPT_LENGTH]],
        dtype=np.int64,
    )

    # ---------------------------------------------------------
    # ONNX Runtime session
    # ---------------------------------------------------------

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

    # ---------------------------------------------------------
    # Build exact feed
    # ---------------------------------------------------------

    feed = {
        "inputs_embeds": x,
        "position_ids": position_ids,
    }

    kv_count = 4 * PROMPT_LENGTH * 64

    for i in range(N_LAYERS):
        path = (
            RUST_ROOT
            / f"rust_prefill_{1 + i:02d}.f32"
        )

        k = read_f32(
            path,
            kv_count,
        ).reshape(
            1,
            4,
            PROMPT_LENGTH,
            64,
        )

        feed[f"past_k_{i}"] = k

    for i in range(N_LAYERS):
        path = (
            RUST_ROOT
            / f"rust_prefill_{13 + i:02d}.f32"
        )

        v = read_f32(
            path,
            kv_count,
        ).reshape(
            1,
            4,
            PROMPT_LENGTH,
            64,
        )

        feed[f"past_v_{i}"] = v

    # ---------------------------------------------------------
    # Run decoder
    # ---------------------------------------------------------

    outputs = session.run(
        None,
        feed,
    )

    names = (
        ["hidden"]
        + [f"present_k_{i}" for i in range(N_LAYERS)]
        + [f"present_v_{i}" for i in range(N_LAYERS)]
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