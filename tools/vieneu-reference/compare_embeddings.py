from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[2]

python_file = (
    ROOT
    / "tools"
    / "vieneu-reference"
    / "python_prompt_embeds.npy"
)

rust_file = (
    ROOT
    / "native"
    / "vieneu_core"
    / "rust_prompt_embeds.f32"
)


python_data = np.load(python_file)

rust_data = np.fromfile(
    rust_file,
    dtype="<f4",
).reshape(
    python_data.shape
)

diff = np.abs(
    python_data.astype(np.float64)
    - rust_data.astype(np.float64)
)

print("Python shape:", python_data.shape)
print("Rust shape:", rust_data.shape)

print("max absolute difference:", diff.max())
print("mean absolute difference:", diff.mean())

print()
print("Python first 10:")
print(python_data.reshape(-1)[:10])

print()
print("Rust first 10:")
print(rust_data.reshape(-1)[:10])