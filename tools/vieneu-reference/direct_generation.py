from pathlib import Path
import json

import numpy as np
import onnxruntime as ort


ROOT = Path(
    "/Users/lawrencewong/Movies/vietnamese_shadowing"
)

MODEL_DIR = ROOT / "assets/vieneu/model"

OUT_DIR = (
    ROOT
    / "tools/vieneu-reference/direct_generation"
)

OUT_DIR.mkdir(
    parents=True,
    exist_ok=True,
)

HIDDEN = 768
N_VQ = 16
N_LAYERS = 12

AUDIO_HEADS = 8
AUDIO_HEAD_DIM = 96

SGS = 5
EOS = 6

NUM_FRAMES = 3

PHONEMES = (
    "hˈom nˈaj bˈaː6n xwˈɛ4 xˌoŋ?"
)


def make_session(path):
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

    return ort.InferenceSession(
        str(path),
        so,
        providers=["CPUExecutionProvider"],
    )


def argmax_scalar(values):
    best_index = 0
    best_value = -np.inf

    for i, value in enumerate(values):
        if value > best_value:
            best_value = value
            best_index = i

    return best_index


def save_f32(path, values):
    np.asarray(
        values,
        dtype=np.float32,
    ).astype(
        "<f4",
        copy=False,
    ).tofile(path)


def save_i64(path, values):
    np.asarray(
        values,
        dtype=np.int64,
    ).astype(
        "<i8",
        copy=False,
    ).tofile(path)


def main():
    # =========================================================
    # Heads
    # =========================================================

    print("Loading heads...")

    z = np.load(
        MODEL_DIR
        / "vieneu_v3_heads.npz"
    )

    text_emb = z[
        "text_emb"
    ].astype(
        np.float32,
        copy=False,
    )

    audio_emb = z[
        "audio_emb"
    ].astype(
        np.float32,
        copy=False,
    )

    print(
        "text_emb:",
        text_emb.shape,
    )

    print(
        "audio_emb:",
        audio_emb.shape,
    )

    # =========================================================
    # Python engine
    # Used for tokenizer / prompt / speaker anchor.
    # =========================================================

    from vieneu._v3_turbo_engine.onnx_runtime_lite import (
        OnnxV3LiteEngine,
    )

    engine = OnnxV3LiteEngine(
        onnx_dir=str(MODEL_DIR),
        threads=1,
    )

    # =========================================================
    # Xuân Vĩnh
    # =========================================================

    voice_path = (
        ROOT
        / "assets/vieneu/voices_v3_turbo.json"
    )

    with open(
        voice_path,
        "r",
        encoding="utf-8",
    ) as f:
        voice_file = json.load(f)

    voice = (
        voice_file[
            "presets"
        ][
            "Xuân Vĩnh"
        ]
    )

    speaker_emb = np.asarray(
        voice["speaker_emb"],
        dtype=np.float32,
    )

    ref_codes = np.asarray(
        voice["codes"],
        dtype=np.int64,
    )

    print(
        "speaker_emb:",
        speaker_emb.shape,
    )

    print(
        "ref_codes:",
        ref_codes.shape,
    )

    # =========================================================
    # Anchor
    # =========================================================

    anchor = engine._speaker_anchor(
        speaker_emb
    )

    print(
        "anchor:",
        anchor.shape,
    )

    save_f32(
        OUT_DIR
        / "python_generation_anchor.f32",
        anchor,
    )

    # =========================================================
    # Prompt
    # =========================================================

    style_id = (
        engine._resolve_style_id()
    )

    rows = engine._build_rows(
        PHONEMES,
        ref_codes,
        style_id,
    )

    prompt_embeds = engine._embed_rows(
        rows,
        anchor,
    )

    print(
        "Prompt shape:",
        prompt_embeds.shape,
    )

    # =========================================================
    # ONNX sessions
    # =========================================================

    print("Loading prefill...")

    sess_pre = make_session(
        MODEL_DIR
        / "vieneu_prefill.onnx"
    )

    print(
        "Loading backbone decode..."
    )

    sess_dec = make_session(
        MODEL_DIR
        / "vieneu_decode_step.onnx"
    )

    print(
        "Loading acoustic decoder..."
    )

    sess_ac = make_session(
        MODEL_DIR
        / "vieneu_acoustic_cached.onnx"
    )

    # =========================================================
    # PREFILL
    # =========================================================

    print()
    print("Running prefill...")

    pre = sess_pre.run(
        None,
        {
            "inputs_embeds":
                prompt_embeds,
        },
    )

    h = np.asarray(
        pre[0][:, -1],
        dtype=np.float32,
    )

    save_f32(
        OUT_DIR
        / "python_generation_prefill_hidden.f32",
        h,
    )

    past_k = [
        np.asarray(
            pre[1 + i],
            dtype=np.float32,
        )
        for i in range(N_LAYERS)
    ]

    past_v = [
        np.asarray(
            pre[
                1
                + N_LAYERS
                + i
            ],
            dtype=np.float32,
        )
        for i in range(N_LAYERS)
    ]

    Tprompt = (
        prompt_embeds.shape[1]
    )

    print(
        "Prompt length:",
        Tprompt,
    )

    # =========================================================
    # Acoustic frame
    # =========================================================

    def acoustic_frame(
        current_h,
        frame_index,
    ):
        cond = np.asarray(
            current_h[0],
            dtype=np.float32,
        )

        txt = text_emb[
            SGS
        ].astype(
            np.float32,
            copy=False,
        )

        # -----------------------------------------------------
        # Initial acoustic call
        # -----------------------------------------------------

        tok = np.stack(
            [
                cond,
                txt,
            ]
        )[None].astype(
            np.float32,
        )

        out = sess_ac.run(
            None,
            {
                "token_emb":
                    tok,

                "position_ids":
                    np.array(
                        [[0, 1]],
                        dtype=np.int64,
                    ),

                "past_k_0":
                    np.zeros(
                        (
                            1,
                            AUDIO_HEADS,
                            0,
                            AUDIO_HEAD_DIM,
                        ),
                        dtype=np.float32,
                    ),

                "past_v_0":
                    np.zeros(
                        (
                            1,
                            AUDIO_HEADS,
                            0,
                            AUDIO_HEAD_DIM,
                        ),
                        dtype=np.float32,
                    ),
            },
        )

        hidden = np.asarray(
            out[0],
            dtype=np.float32,
        )

        pk = np.asarray(
            out[1],
            dtype=np.float32,
        )

        pv = np.asarray(
            out[2],
            dtype=np.float32,
        )

        save_f32(
            OUT_DIR
            / f"python_generation_frame{frame_index}_acoustic_ch00_hidden.f32",
            hidden,
        )

        slot0 = hidden[
            0,
            0,
        ]

        # -----------------------------------------------------
        # Channel 0
        # -----------------------------------------------------

        logits = np.matmul(
            hidden[
                0,
                1,
            ],
            audio_emb[0].T,
        ).astype(
            np.float32,
        )

        save_f32(
            OUT_DIR
            / f"python_generation_frame{frame_index}_acoustic_ch00_logits.f32",
            logits,
        )

        code0 = argmax_scalar(
            logits
        )

        codes = [
            code0
        ]

        # -----------------------------------------------------
        # Channels 1..15
        # -----------------------------------------------------

        for ch in range(1, N_VQ):
            previous_code = (
                codes[-1]
            )

            emb = audio_emb[
                ch - 1,
                previous_code,
            ].astype(
                np.float32,
                copy=False,
            )

            out = sess_ac.run(
                None,
                {
                    "token_emb":
                        emb.reshape(
                            1,
                            1,
                            HIDDEN,
                        ),

                    "position_ids":
                        np.array(
                            [[ch + 1]],
                            dtype=np.int64,
                        ),

                    "past_k_0":
                        pk,

                    "past_v_0":
                        pv,
                },
            )

            hidden = np.asarray(
                out[0],
                dtype=np.float32,
            )

            pk = np.asarray(
                out[1],
                dtype=np.float32,
            )

            pv = np.asarray(
                out[2],
                dtype=np.float32,
            )

            save_f32(
                OUT_DIR
                / f"python_generation_frame{frame_index}_acoustic_ch{ch:02d}_hidden.f32",
                hidden,
            )

            logits = np.matmul(
                hidden[
                    0,
                    0,
                ],
                audio_emb[ch].T,
            ).astype(
                np.float32,
            )

            save_f32(
                OUT_DIR
                / f"python_generation_frame{frame_index}_acoustic_ch{ch:02d}_logits.f32",
                logits,
            )

            codes.append(
                argmax_scalar(
                    logits
                )
            )

        # -----------------------------------------------------
        # EOS
        # -----------------------------------------------------

        text_logits = np.matmul(
            slot0,
            text_emb.T,
        ).astype(
            np.float32,
        )

        eos_token = argmax_scalar(
            text_logits
        )

        save_f32(
            OUT_DIR
            / f"python_generation_frame{frame_index}_acoustic_text_logits.f32",
            text_logits,
        )

        return (
            np.asarray(
                codes,
                dtype=np.int64,
            ),
            eos_token == EOS,
        )

    # =========================================================
    # Generation
    # =========================================================

    frames = []

    for t in range(NUM_FRAMES):
        print()
        print("=" * 50)
        print(
            f"FRAME {t}"
        )
        print("=" * 50)

        codes, eos = acoustic_frame(
            h,
            t,
        )

        frames.append(
            codes.copy()
        )

        print(
            "codes:",
            codes.tolist(),
        )

        print(
            "EOS:",
            eos,
        )

        save_i64(
            OUT_DIR
            / f"python_generation_frame{t}_codes.i64",
            codes,
        )

        if eos:
            break

        # -----------------------------------------------------
        # Build next backbone embedding.
        #
        # Save every component separately.
        # -----------------------------------------------------

        text_component = (
            text_emb[SGS]
            .astype(
                np.float32,
                copy=True,
            )
        )

        save_f32(
            OUT_DIR
            / f"python_generation_frame{t}_text.f32",
            text_component,
        )

        text_audio = (
            text_component.copy()
        )

        for ch in range(N_VQ):
            selected_audio = audio_emb[
                ch,
                int(codes[ch]),
            ]

            text_audio += selected_audio

            save_f32(
                OUT_DIR
                / f"python_generation_frame{t}_audio_emb_{ch:02d}.f32",
                selected_audio,
            )

        save_f32(
            OUT_DIR
            / f"python_generation_frame{t}_text_audio.f32",
            text_audio,
        )

        save_f32(
            OUT_DIR
            / f"python_generation_frame{t}_anchor.f32",
            anchor,
        )

        next_embedding = (
            text_audio + anchor
        ).astype(
            np.float32,
            copy=False,
        )

        save_f32(
            OUT_DIR
            / f"python_generation_frame{t}_backbone_input.f32",
            next_embedding,
        )

        # -----------------------------------------------------
        # Backbone decode
        # -----------------------------------------------------

        position = (
            Tprompt + t
        )

        feed = {
            "inputs_embeds":
                next_embedding.reshape(
                    1,
                    1,
                    HIDDEN,
                ),

            "position_ids":
                np.array(
                    [[position]],
                    dtype=np.int64,
                ),
        }

        for i in range(N_LAYERS):
            feed[
                f"past_k_{i}"
            ] = past_k[i]

            feed[
                f"past_v_{i}"
            ] = past_v[i]

        print(
            "Running backbone decode..."
        )

        out = sess_dec.run(
            None,
            feed,
        )

        h = np.asarray(
            out[0][:, 0],
            dtype=np.float32,
        )

        save_f32(
            OUT_DIR
            / f"python_generation_frame{t + 1}_backbone_hidden.f32",
            h,
        )

        past_k = [
            np.asarray(
                out[1 + i],
                dtype=np.float32,
            )
            for i in range(N_LAYERS)
        ]

        past_v = [
            np.asarray(
                out[
                    1
                    + N_LAYERS
                    + i
                ],
                dtype=np.float32,
            )
            for i in range(N_LAYERS)
        ]

        print(
            "backbone cache:",
            past_k[0].shape[2],
        )

    # =========================================================
    # Final frames
    # =========================================================

    print()
    print("=" * 50)
    print(
        "PYTHON FRAMES"
    )
    print("=" * 50)

    for i, frame in enumerate(
        frames
    ):
        print(
            f"frame {i}:",
            frame.tolist(),
        )


if __name__ == "__main__":
    main()