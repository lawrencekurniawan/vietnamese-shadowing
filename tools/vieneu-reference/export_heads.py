from pathlib import Path
import json

import numpy as np


ROOT = Path(__file__).resolve().parents[2]

INPUT = ROOT / "assets/vieneu/model/vieneu_v3_heads.npz"
OUTPUT = ROOT / "assets/vieneu/model/vieneu_heads.json"


def array_to_json(array: np.ndarray):
    return {
        "shape": list(array.shape),
        "data": array.astype(np.float32).reshape(-1).tolist(),
    }


def main() -> None:
    with np.load(INPUT) as data:
        output = {
            "text_emb": array_to_json(data["text_emb"]),
            "audio_emb": array_to_json(data["audio_emb"]),
            "xvec_w": array_to_json(data["xvec_w"]),
            "xvec_b": array_to_json(data["xvec_b"]),
            "xvec_ln_w": array_to_json(data["xvec_ln_w"]),
            "xvec_ln_b": array_to_json(data["xvec_ln_b"]),
            "xvec_ln_eps": float(data["xvec_ln_eps"]),
        }

    OUTPUT.write_text(
        json.dumps(output),
        encoding="utf-8",
    )

    print(f"Wrote {OUTPUT}")
    

if __name__ == "__main__":
    main()