from pathlib import Path

import numpy as np
import onnxruntime as ort


ROOT = Path(
    "/Users/lawrencewong/Movies/vietnamese_shadowing"
)

MODEL = (
    ROOT
    / "assets/vieneu/codec/"
    "moss_audio_tokenizer_decode_full.onnx"
)

OUT_DIR = (
    ROOT
    / "tools/vieneu-reference/codec_test"
)

OUT_DIR.mkdir(
    parents=True,
    exist_ok=True,
)


def main():
    # ---------------------------------------------------------
    # Exact same 3 frames as Rust.
    # Shape: (3, 16)
    # ---------------------------------------------------------

    codes = np.array(
        [
            [
                482, 194, 670, 241,
                909, 406, 417, 626,
                171, 334, 923, 273,
                870, 689, 272, 49,
            ],
            [
                741, 471, 176, 747,
                908, 804, 326, 869,
                127, 644, 825, 690,
                673, 81, 603, 697,
            ],
            [
                511, 726, 793, 357,
                1014, 343, 214, 687,
                420, 798, 1015, 764,
                852, 802, 2, 184,
            ],
        ],
        dtype=np.int32,
    )

    audio_codes = codes[None]

    audio_code_lengths = np.array(
        [codes.shape[0]],
        dtype=np.int32,
    )

    print(
        "audio_codes shape:",
        audio_codes.shape,
    )

    print(
        "audio_code_lengths:",
        audio_code_lengths,
    )

    # ---------------------------------------------------------
    # ORT
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
        providers=[
            "CPUExecutionProvider"
        ],
    )

    print()
    print(
        "Providers:",
        session.get_providers(),
    )

    # ---------------------------------------------------------
    # Decode
    # ---------------------------------------------------------

    outputs = session.run(
        None,
        {
            "audio_codes":
                audio_codes,

            "audio_code_lengths":
                audio_code_lengths,
        },
    )

    audio = np.asarray(
        outputs[0],
        dtype=np.float32,
    )

    audio_lengths = np.asarray(
        outputs[1],
        dtype=np.int32,
    )

    print()
    print(
        "Audio shape:",
        audio.shape,
    )

    print(
        "Audio values:",
        audio.size,
    )

    print(
        "Audio first 20 values:"
    )

    print(
        audio.reshape(-1)[:20]
    )

    print()
    print(
        "audio_lengths:",
        audio_lengths,
    )

    # ---------------------------------------------------------
    # Exact Python reference operation:
    #
    # out[0][0].mean(0)
    # ---------------------------------------------------------

    wav = (
        audio[0]
        .mean(0)
        .astype(np.float32)
    )

    print()
    print(
        "Waveform shape:",
        wav.shape,
    )

    print(
        "Waveform first 20:"
    )

    print(
        wav[:20]
    )

    wav.astype(
        "<f4",
        copy=False,
    ).tofile(
        OUT_DIR / "python_codec_wav.f32"
    )

    print()
    print(
        "Saved:",
        OUT_DIR / "python_codec_wav.f32",
    )


if __name__ == "__main__":
    main()