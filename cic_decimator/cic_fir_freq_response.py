#!/usr/bin/env python3

"""
Plot the full-band frequency response of a CIC decimator and an optional post-decimation FIR filter.
"""

import math
import re
import sys
from pathlib import Path

import matplotlib
import numpy as np
from scipy.signal import freqz

matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.append(str(Path(__file__).parent.parent / "numeric"))
from fixpoint import from_fixpoint


def read_fir_kernel(path: Path) -> tuple[np.ndarray, tuple[int, int]]:
    text = path.read_text()
    q_match = re.search(r"\bq([1-9]\d*)\.(\d+)\b", text)
    words: list[str] = []
    for line_no, line in enumerate(text.splitlines(), 1):
        value = line.split("//", 1)[0].strip().replace("_", "")
        if not value:
            continue
        if not re.fullmatch(r"[01]+", value):
            raise ValueError(f"{path}:{line_no}: expected a binary coefficient, got {value!r}")
        words.append(value)
    if not words:
        raise ValueError(f"No FIR coefficients found in {path}")
    widths = {len(word) for word in words}
    if len(widths) != 1:
        raise ValueError(f"Inconsistent FIR coefficient widths in {path}: {sorted(widths)}")
    width = widths.pop()
    q = (int(q_match.group(1)), int(q_match.group(2))) if q_match else (1, width - 1)
    if sum(q) != width:
        raise ValueError(f"{path}: q{q[0]}.{q[1]} does not match {width}-bit coefficients")
    return np.array([from_fixpoint(q, word) for word in words], dtype=float)


def cic_response_normalized(
    *,
    frequencies: np.ndarray,
    f_s_cic: float,
    R_cic: int,
    M_cic: int,
    N_cic: int,
) -> np.ndarray:
    """Magnitude response of the CIC filter normalized to unity DC gain."""
    x = math.pi * frequencies / f_s_cic
    response = np.ones_like(frequencies, dtype=float)
    nonzero = np.abs(x) > 1e-15
    with np.errstate(divide="ignore", invalid="ignore"):
        response[nonzero] = np.abs(
            np.sin(R_cic * M_cic * x[nonzero]) / ((R_cic * M_cic) * np.sin(x[nonzero]))
        ) ** N_cic
    response[~np.isfinite(response)] = 0.0
    return response


def fir_response_periodic(
    *,
    kernel: np.ndarray,
    frequencies: np.ndarray,
    f_s_fir: float,
) -> np.ndarray:
    """Frequency response of the post-decimation FIR, repeated over the CIC input-frequency axis."""
    folded_frequencies = np.mod(frequencies, f_s_fir)
    angular_frequencies = 2 * math.pi * folded_frequencies / f_s_fir
    _, response = freqz(kernel, worN=angular_frequencies)
    return response


def plot_response(
    *,
    f_s_cic: float,
    R_cic: int,
    M_cic: int,
    N_cic: int,
    frequencies: np.ndarray,
    h_cic: np.ndarray,
    h_fir: np.ndarray | None,
    fir_name: str | None,
    out: Path,
) -> None:
    fig, (ax_lin, ax_db) = plt.subplots(
        2, 1, sharex=True, figsize=(15, 10), gridspec_kw={"height_ratios": [2, 1]}
    )

    frequencies = frequencies * 1e-3
    traces = [(np.abs(h_cic), "b", "CIC")]
    if h_fir is not None:
        traces += [
            (np.abs(h_fir), "r", "FIR quantized"),
            (np.abs(h_cic * h_fir), "k", "total"),
        ]

    for magnitude, color, label in traces:
        ax_lin.plot(frequencies, magnitude, color=color, linestyle="-", linewidth=1.0, label=label)
        ax_db.plot(
            frequencies,
            20.0 * np.log10(np.maximum(magnitude, 1e-12)),
            color=color,
            linestyle="-",
            linewidth=1.0,
            label=label,
        )

    ax_lin.set_ylim(bottom=0.0)
    ax_lin.set_ylabel("Magnitude [1]")
    ax_db.set_xlim(0.0, f_s_cic * 0.125 * 1e-3)
    ax_db.set_ylim(bottom=-150.0)
    ax_db.set_xlabel("Frequency [kHz]")
    ax_db.set_ylabel("Magnitude [dB]")
    for ax in (ax_lin, ax_db):
        ax.grid(True, which="both")
        ax.legend(loc="best")
        ax.minorticks_on()

    title = f"{f_s_cic=:e} {R_cic=} {M_cic=} {N_cic=}"
    if fir_name is not None:
        title += f" fir={fir_name!r}"
    fig.suptitle(title)
    plt.tight_layout()
    fig.savefig(out, dpi=192, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    # Resolve CIC params.
    f_s_cic, R_cic = float(sys.argv[1]), int(sys.argv[2], 0)
    N_cic = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    M_cic = int(sys.argv[4]) if len(sys.argv) > 4 else 1

    # Resolve FIR params.
    fir_name = sys.argv[5] if len(sys.argv) > 5 else None
    fir_kernel: np.ndarray | None = None
    if fir_name:
        if not fir_name.endswith(".fir.memb"):
            fir_name += ".fir.memb"
        if fir_kernel_file := next(Path('.').rglob(fir_name), None):
            fir_kernel = read_fir_kernel(fir_kernel_file)

    # Process. Sample at many points to resolve narrow notches well.
    print(f"{f_s_cic=} {R_cic=} {N_cic=} {M_cic=} {fir_name=}")
    frequencies = np.linspace(0.0, f_s_cic * 0.5, 2**20)
    h_cic = cic_response_normalized(
        frequencies=frequencies,
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
    )

    f_s_fir = f_s_cic / R_cic
    h_fir = None if fir_kernel is None else fir_response_periodic(
        kernel=fir_kernel,
        frequencies=frequencies,
        f_s_fir=f_s_fir,
    )

    fir_name=fir_name.split(".", 1)[0] if fir_name else None
    title = f"{f_s_cic=:.0f},{N_cic=},{M_cic=},fir={fir_name}"
    plot_response(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        frequencies=frequencies,
        h_cic=h_cic,
        h_fir=h_fir,
        fir_name=fir_name,
        out=Path(f"cic_fir_freq_response.{title}.png"),
    )


if __name__ == "__main__":
    main()
