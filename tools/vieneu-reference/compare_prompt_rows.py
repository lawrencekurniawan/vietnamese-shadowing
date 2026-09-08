from pathlib import Path

import numpy as np


ROOT = Path(
    "/Users/lawrencewong/Movies/vietnamese_shadowing"
)

PYTHON_FILE = (
    ROOT
    / "tools/vieneu-reference"
    / "python_prompt_embeddings.f32"
)

RUST_FILE = (
    ROOT
    / "native/vieneu_core"
    / "rust_prompt_embeddings.f32"
)


python = np.fromfile(
    PYTHON_FILE,
    dtype="<f4",
).reshape(1, 67, 768)

rust = np.fromfile(
    RUST_FILE,
    dtype="<f4",
).reshape(1, 67, 768)


print("Python shape:", python.shape)
print("Rust shape:  ", rust.shape)

print()
print(
    "Overall max:",
    np.max(
        np.abs(
            python.astype(np.float64)
            - rust.astype(np.float64)
        )
    ),
)

print(
    "Overall mean:",
    np.mean(
        np.abs(
            python.astype(np.float64)
            - rust.astype(np.float64)
        )
    ),
)

print()
print(
    "Row-by-row differences:"
)

first_different = None

for row in range(67):
    diff = np.abs(
        python[0, row].astype(np.float64)
        - rust[0, row].astype(np.float64)
    )

    max_diff = float(diff.max())
    mean_diff = float(diff.mean())

    print(
        f"row {row:02d}: "
        f"max={max_diff:.9e} "
        f"mean={mean_diff:.9e}"
    )

    if (
        first_different is None
        and max_diff != 0.0
    ):
        first_different = row

print()

if first_different is None:
    print("All rows are bit-for-bit identical.")
else:
    print(
        "First differing row:",
        first_different,
    )

    row = first_different

    print()
    print("Python first 20 values:")
    print(
        python[0, row, :20]
    )

    print()
    print("Rust first 20 values:")
    print(
        rust[0, row, :20]
    )

    print()
    print("Differences first 20:")
    print(
        (
            python[0, row, :20].astype(np.float64)
            - rust[0, row, :20].astype(np.float64)
        )
    )