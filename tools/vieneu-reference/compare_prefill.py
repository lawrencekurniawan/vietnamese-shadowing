from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[2]

RUST_DIR = (
    ROOT
    / "native"
    / "vieneu_core"
)

PYTHON_DIR = (
    ROOT
    / "tools"
    / "vieneu-reference"
    / "python_prefill_noopt_run2"
)

names = (
    ["hidden"]
    + [
        f"present_k_{i}"
        for i in range(12)
    ]
    + [
        f"present_v_{i}"
        for i in range(12)
    ]
)

shapes = (
    [(1, 67, 768)]
    + [(1, 4, 67, 64)] * 24
)


overall_max = 0.0
overall_mean_sum = 0.0

for index, (name, shape) in enumerate(
    zip(names, shapes)
):
    rust_file = (
        RUST_DIR
        / f"rust_prefill_{index:02}.f32"
    )

    python_file = (
        PYTHON_DIR
        / f"python_prefill_{index:02}.f32"
    )

    if not rust_file.exists():
        raise FileNotFoundError(
            f"Missing Rust file: {rust_file}"
        )

    if not python_file.exists():
        raise FileNotFoundError(
            f"Missing Python file: {python_file}"
        )

    rust = np.fromfile(
        rust_file,
        dtype="<f4",
    )

    python = np.fromfile(
        python_file,
        dtype="<f4",
    )

    expected_size = int(np.prod(shape))

    if rust.size != expected_size:
        raise RuntimeError(
            f"{name}: Rust has {rust.size} "
            f"values, expected {expected_size}"
        )

    if python.size != expected_size:
        raise RuntimeError(
            f"{name}: Python has {python.size} "
            f"values, expected {expected_size}"
        )

    rust = rust.reshape(shape)
    python = python.reshape(shape)

    diff = np.abs(
        rust.astype(np.float64)
        - python.astype(np.float64)
    )

    max_diff = float(diff.max())
    mean_diff = float(diff.mean())

    overall_max = max(
        overall_max,
        max_diff,
    )

    overall_mean_sum += mean_diff

    print(
        f"{index:02} {name:16s} "
        f"max={max_diff:.9e} "
        f"mean={mean_diff:.9e}"
    )

print()
print(
    f"OVERALL max={overall_max:.9e}"
)

print(
    f"OVERALL mean="
    f"{overall_mean_sum / len(names):.9e}"
)