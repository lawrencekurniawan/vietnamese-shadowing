from pathlib import Path

import numpy as np
import onnxruntime as ort


ROOT = Path("/Users/lawrencewong/Movies/vietnamese_shadowing")

MODEL = (
    ROOT
    / "assets/vieneu/model/vieneu_acoustic_cached.onnx"
)

HEADS = (
    ROOT
    / "assets/vieneu/model/vieneu_v3_heads.npz"
)

RUST_ROOT = (
    ROOT
    / "native/vieneu_core"
)

OUTPUT_DIR = (
    ROOT
    / "tools/vieneu-reference/direct_acoustic"
)

OUTPUT_DIR.mkdir(
    parents=True,
    exist_ok=True,
)

HIDDEN = 768
N_VQ = 16
N_HEADS = 8
HEAD_DIM = 96

SGS = 5


def read_f32(path: Path, count=None):
    x = np.fromfile(
        path,
        dtype="<f4",
    )

    if count is not None and len(x) != count:
        raise RuntimeError(
            f"{path}: expected {count} values, got {len(x)}"
        )

    return x


def save_f32(
    path: Path,
    x: np.ndarray,
):
    np.asarray(
        x,
        dtype=np.float32,
    ).astype(
        "<f4",
        copy=False,
    ).tofile(path)


def dot_scalar(
    x: np.ndarray,
    y: np.ndarray,
) -> float:
    # Reproduce a simple float32 dot as closely as practical.
    total = np.float32(0.0)

    for i in range(len(x)):
        total = np.float32(
            total
            + np.float32(x[i] * y[i])
        )

    return float(total)


def argmax_scalar(
    values,
):
    best_index = 0
    best_value = -np.inf

    for i, value in enumerate(values):
        if value > best_value:
            best_value = value
            best_index = i

    return best_index


def main():
    print("Loading heads...")

    z = np.load(HEADS)

    text_emb = z["text_emb"].astype(
        np.float32,
        copy=False,
    )

    audio_emb = z["audio_emb"].astype(
        np.float32,
        copy=False,
    )

    print("text_emb:", text_emb.shape)
    print("audio_emb:", audio_emb.shape)

    # ---------------------------------------------------------
    # Exact hidden state produced by Rust decoder.
    # ---------------------------------------------------------

    cond = read_f32(
        RUST_ROOT / "rust_decode_00.f32",
        HIDDEN,
    )

    print()
    print("Conditioning hidden:", cond.shape)
    print("first 10:", cond[:10])

    # ---------------------------------------------------------
    # SGS embedding.
    # ---------------------------------------------------------

    sgs_embedding = (
        text_emb[SGS]
        .astype(np.float32, copy=False)
    )

    # ---------------------------------------------------------
    # First acoustic input:
    #
    # [decoder hidden, SGS embedding]
    # ---------------------------------------------------------

    token_emb = np.concatenate(
        [
            cond,
            sgs_embedding,
        ]
    ).astype(
        np.float32,
        copy=False,
    ).reshape(
        1, 2, HIDDEN
    )

    position_ids = np.array(
        [[0, 1]],
        dtype=np.int64,
    )

    empty_k = np.zeros(
        (1, N_HEADS, 0, HEAD_DIM),
        dtype=np.float32,
    )

    empty_v = np.zeros(
        (1, N_HEADS, 0, HEAD_DIM),
        dtype=np.float32,
    )

    # ---------------------------------------------------------
    # ONNX Runtime
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
    # First acoustic call
    # ---------------------------------------------------------

    out = session.run(
        None,
        {
            "token_emb": token_emb,
            "position_ids": position_ids,
            "past_k_0": empty_k,
            "past_v_0": empty_v,
        },
    )

    hidden = np.asarray(
        out[0],
        dtype=np.float32,
    )

    past_k = np.asarray(
        out[1],
        dtype=np.float32,
    )

    past_v = np.asarray(
        out[2],
        dtype=np.float32,
    )

    print()
    print("Acoustic step 0")
    print("hidden shape:", hidden.shape)
    print("hidden first 10:")
    print(hidden.reshape(-1)[:10])

    save_f32(
        OUTPUT_DIR / "python_acoustic_step0_hidden.f32",
        hidden,
    )

    save_f32(
        OUTPUT_DIR / "python_acoustic_step0_k.f32",
        past_k,
    )

    save_f32(
        OUTPUT_DIR / "python_acoustic_step0_v.f32",
        past_v,
    )

    # ---------------------------------------------------------
    # Code 0
    #
    # Python reference:
    #
    # logits =
    #   hidden[0, 1] @ audio_emb[0].T
    # ---------------------------------------------------------

    channel_hidden = hidden[0, 1]

    logits0 = np.matmul(
        channel_hidden.astype(np.float32),
        audio_emb[0].T.astype(np.float32),
    ).astype(np.float32)

    save_f32(
        OUTPUT_DIR / "python_acoustic_code0_logits.f32",
        logits0,
    )

    code0 = int(
        np.argmax(logits0)
    )

    print("code[0] =", code0)

    # ---------------------------------------------------------
    # EOS check
    #
    # Python reference:
    #
    # text_logits = slot0 @ text_emb.T
    # ---------------------------------------------------------

    slot0 = hidden[0, 0]

    text_logits = np.matmul(
        slot0.astype(np.float32),
        text_emb.T.astype(np.float32),
    ).astype(np.float32)

    save_f32(
        OUTPUT_DIR / "python_acoustic_text_logits.f32",
        text_logits,
    )

    eos_argmax = int(
        np.argmax(text_logits)
    )

    print("EOS argmax token =", eos_argmax)

    codes = [code0]

    # ---------------------------------------------------------
    # Remaining channels
    # ---------------------------------------------------------

    for ch in range(1, N_VQ):
        previous_code = codes[-1]

        embedding = (
            audio_emb[ch - 1, previous_code]
            .astype(np.float32, copy=False)
        )

        token_emb = embedding.reshape(
            1, 1, HIDDEN
        )

        position_ids = np.array(
            [[ch + 1]],
            dtype=np.int64,
        )

        out = session.run(
            None,
            {
                "token_emb": token_emb,
                "position_ids": position_ids,
                "past_k_0": past_k,
                "past_v_0": past_v,
            },
        )

        hidden = np.asarray(
            out[0],
            dtype=np.float32,
        )

        past_k = np.asarray(
            out[1],
            dtype=np.float32,
        )

        past_v = np.asarray(
            out[2],
            dtype=np.float32,
        )

        save_f32(
            OUTPUT_DIR
            / f"python_acoustic_step{ch}_hidden.f32",
            hidden,
        )

        save_f32(
            OUTPUT_DIR
            / f"python_acoustic_step{ch}_k.f32",
            past_k,
        )

        save_f32(
            OUTPUT_DIR
            / f"python_acoustic_step{ch}_v.f32",
            past_v,
        )

        current_hidden = hidden[0, 0]

        logits = np.matmul(
            current_hidden.astype(np.float32),
            audio_emb[ch].T.astype(np.float32),
        ).astype(np.float32)

        save_f32(
            OUTPUT_DIR
            / f"python_acoustic_code{ch}_logits.f32",
            logits,
        )

        code = int(
            np.argmax(logits)
        )

        codes.append(code)

        print(
            f"code[{ch}] = {code}"
            f"   cache_length={past_k.shape[2]}"
        )

    print()
    print("Python codes:")
    print(codes)

    print()
    print(
        "Python EOS argmax:",
        eos_argmax,
    )


if __name__ == "__main__":
    main()