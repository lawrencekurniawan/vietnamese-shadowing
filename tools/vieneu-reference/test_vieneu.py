from pathlib import Path

from vieneu import Vieneu


def main() -> None:
    print("Loading VieNeu v3 Turbo...")

    tts = Vieneu(
        mode="v3turbo",
        backend="onnx",
        device="cpu",
    )

    print("VieNeu loaded.")

    voices = tts.list_preset_voices()

    print(f"Available preset voices: {len(voices)}")
    for label, voice_id in voices:
        print(f"  {label} ({voice_id})")

    text = "Hôm nay bạn khỏe không?"

    print()
    print(f"Generating: {text!r}")

    audio = tts.infer(
        text,
        voice="Xuân Vĩnh",
    )

    print(f"Audio shape: {audio.shape}")
    print(f"Audio dtype: {audio.dtype}")

    output = Path("vieneu_test.wav")

    tts.save(
        audio,
        str(output),
    )

    print(f"Saved: {output.resolve()}")


if __name__ == "__main__":
    main()