import json
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[2]

HEADS = ROOT / "assets/vieneu/model/vieneu_v3_heads.npz"
VOICES = ROOT / "assets/vieneu/voices_v3_turbo.json"


def main():
    with np.load(HEADS) as z:
        xvec_w = z["xvec_w"].astype(np.float32)
        xvec_b = z["xvec_b"].astype(np.float32)
        ln_w = z["xvec_ln_w"].astype(np.float32)
        ln_b = z["xvec_ln_b"].astype(np.float32)
        eps = float(z["xvec_ln_eps"])

    voices = json.loads(
        VOICES.read_text(encoding="utf-8")
    )

    voice = voices["presets"]["Xuân Vĩnh"]

    speaker_emb = np.asarray(
        voice["speaker_emb"],
        dtype=np.float32,
    )

    v = speaker_emb @ xvec_w.T + xvec_b

    v = (
        (v - v.mean())
        / np.sqrt(v.var() + eps)
    )

    anchor = (
        v * ln_w + ln_b
    ).astype(np.float32)

    print("Anchor shape:", anchor.shape)
    print("First 10 values:")

    for x in anchor[:10]:
        print(f"{x:.9f}")


if __name__ == "__main__":
    main()