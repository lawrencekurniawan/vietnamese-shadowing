from pathlib import Path
import numpy as np

path = Path("assets/vieneu/model/vieneu_v3_heads.npz")

with np.load(path) as data:
    print("VieNeu heads:")
    for key in data.files:
        value = data[key]
        print(f"  {key:16s} shape={value.shape} dtype={value.dtype}")