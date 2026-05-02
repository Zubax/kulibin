#!/usr/bin/env python3

"""
Plot the full-band frequency response of a CIC decimator and an optional post-decimation FIR filter.
"""

import math
import sys
from pathlib import Path

import matplotlib
import numpy as np
from scipy.signal import freqz

matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.append(str(Path(__file__).parent.parent / "fir"))
from fir import fir_kernel_from_verilog_fixpoint


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


def cic_fir_group_delay(f_s_cic: float, R_cic: int, N_cic: int, M_cic: int, N_fir: int):
    """
    Compute the group delay of a CIC decimator followed by a linear-phase FIR compensator of order N_fir (N_fir+1 taps).
    Returns a tuple of: (CIC group delay, FIR group delay) in seconds; sum to get the total.
    N_fir can be zero if not relevant.
    """
    f_s_out = f_s_cic / R_cic

    tau_cic_input_samples = N_cic * (R_cic * M_cic - 1) / 2
    tau_cic = tau_cic_input_samples / f_s_cic

    tau_fir_output_samples = N_fir / 2
    tau_fir = tau_fir_output_samples / f_s_out

    return tau_cic, tau_fir


def plot_response(
    *,
    f_s_cic: float,
    R_cic: int,
    M_cic: int,
    N_cic: int,
    N_fir: int,
    frequencies: np.ndarray,
    h_cic: np.ndarray,
    h_fir: np.ndarray | None,
    fir_name: str | None,
    out: Path,
) -> None:
    fig = plt.figure(figsize=(18, 10))
    gs = fig.add_gridspec(2, 2, width_ratios=[2, 1], height_ratios=[2, 1])
    ax_lin = fig.add_subplot(gs[0, 0])
    ax_db = fig.add_subplot(gs[1, 0], sharex=ax_lin)
    ax_passband = fig.add_subplot(gs[:, 1])

    frequencies = frequencies * 1e-3
    f_s_fir = f_s_cic / R_cic
    traces = [(np.abs(h_cic), "b", "CIC")]
    if h_fir is not None:
        traces += [
            (np.abs(h_fir), "r", "FIR quantized"),
            (np.abs(h_cic * h_fir), "k", "total"),
        ]

    for magnitude, color, label in traces:
        ax_lin.plot(frequencies, magnitude, color=color, linestyle="-", linewidth=1.0, label=label)
        ax_passband.plot(frequencies, magnitude, color=color, linestyle="-", linewidth=1.0, label=label)
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
    ax_db.set_xlim(0.0, frequencies[-1])
    ax_db.set_ylim(bottom=-150.0)
    ax_db.set_xlabel("Frequency [kHz]")
    ax_db.set_ylabel("Magnitude [dB]")
    ax_passband.set_xlim(0.0, f_s_fir * 0.25 * 1e-3)
    ax_passband.set_ylim(0.9, 1.1)
    ax_passband.set_xlabel("Frequency [kHz]")
    ax_passband.set_ylabel("Magnitude [1]")
    ax_passband.set_title("Passband zoom")
    plt.setp(ax_lin.get_xticklabels(), visible=False)
    for ax in (ax_lin, ax_db, ax_passband):
        ax.grid(True, which="both")
        ax.legend(loc="best")
        ax.minorticks_on()

    tau_cic, tau_fir = cic_fir_group_delay(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        N_cic=N_cic,
        M_cic=M_cic,
        N_fir=N_fir,
    )

    title = f"{f_s_cic=:e} {R_cic=} {M_cic=} {N_cic=}"
    if fir_name is not None:
        title += f" fir={fir_name!r}"
    title += f" τ_cic={tau_cic * 1e6:.1f}us τ_fir={tau_fir * 1e6:.1f}us τ_tot={(tau_cic + tau_fir) * 1e6:.1f}us"
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
    N_fir = 0
    if fir_name:
        if not fir_name.endswith(".fir.memb"):
            fir_name += ".fir.memb"
        if fir_kernel_file := next(Path('.').rglob(fir_name), None):
            _, fir_kernel = fir_kernel_from_verilog_fixpoint(fir_kernel_file)
            N_fir = len(fir_kernel) - 1

    # Process. Sample at many points to resolve narrow notches well.
    print(f"{f_s_cic=} {R_cic=} {N_cic=} {M_cic=} {fir_name=}")
    frequencies = np.linspace(0.0, f_s_cic * 0.1, 2**19)
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

    title = f"{f_s_cic=:.0f},{N_cic=},{M_cic=},fir={fir_name}"
    plot_response(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        N_fir=N_fir,
        frequencies=frequencies,
        h_cic=h_cic,
        h_fir=h_fir,
        fir_name=fir_name,
        out=Path(f"cic_fir_freq_response.{title}.png"),
    )


if __name__ == "__main__":
    main()
