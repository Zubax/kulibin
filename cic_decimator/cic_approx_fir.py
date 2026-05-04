#!/usr/bin/env python3

"""
Approximate a CIC decimator with a unity-gain FIR filter running at the CIC output rate.
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

FREQUENCY_SAMPLES = 4096


def cic_output_frequency(R_cic: int, f_s_cic: float) -> float:
    return f_s_cic / R_cic


def cic_group_delay_output_samples(*, R_cic: int, M_cic: int, N_cic: int) -> float:
    return N_cic * (R_cic * M_cic - 1) / (2 * R_cic)


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


def cic_approx_fir_kernel(
    *,
    f_s_cic: float,
    R_cic: int,
    N_cic: int = 3,
    M_cic: int = 1,
    compensation_kernel: np.ndarray | None = None,
) -> np.ndarray:
    """
    Return a unity-gain FIR kernel approximating the CIC, optionally followed by a compensation FIR, at f_s_cic/R_cic.
    The number of taps is selected from the reference group delay. The coefficients are constrained to unity DC gain
    and linear phase, then fit to the normalized reference magnitude response.
    """
    f_s_fir = cic_output_frequency(R_cic, f_s_cic)
    tau_cic_output_samples = cic_group_delay_output_samples(R_cic=R_cic, M_cic=M_cic, N_cic=N_cic)
    tau_reference_output_samples = tau_cic_output_samples
    if compensation_kernel is not None:
        compensation_kernel = normalize_kernel_dc(compensation_kernel)
        tau_reference_output_samples += fir_group_delay_dc_output_samples(compensation_kernel)

    N_fir = max(0, int(math.floor(2 * tau_reference_output_samples + 0.5)))
    taps = N_fir + 1

    angular_frequencies = np.linspace(0.0, math.pi, FREQUENCY_SAMPLES)
    frequencies = angular_frequencies * f_s_fir / (2 * math.pi)
    h_reference = cic_response_normalized(
        frequencies=frequencies,
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
    )
    if compensation_kernel is not None:
        _, h_compensation = freqz(compensation_kernel, worN=angular_frequencies)
        h_reference *= np.abs(h_compensation)

    if taps == 1:
        return np.ones(1)

    symmetry = linear_phase_symmetry_matrix(taps)
    response_matrix = linear_phase_response_matrix(taps, angular_frequencies) @ symmetry
    sum_constraint = np.sum(symmetry, axis=0)
    kernel_base_unique = sum_constraint / np.dot(sum_constraint, sum_constraint)
    _, _, v_t = np.linalg.svd(sum_constraint[None, :])
    kernel_basis_unique = v_t[1:].T
    if kernel_basis_unique.size == 0:
        return symmetry @ kernel_base_unique

    fit_matrix = response_matrix @ kernel_basis_unique
    fit_target = h_reference - response_matrix @ kernel_base_unique
    fit, *_ = np.linalg.lstsq(fit_matrix, fit_target, rcond=None)
    return symmetry @ (kernel_base_unique + kernel_basis_unique @ fit)


def linear_phase_symmetry_matrix(taps: int) -> np.ndarray:
    unique_taps = (taps + 1) // 2
    matrix = np.zeros((taps, unique_taps))
    for index in range(unique_taps):
        matrix[index, index] = 1.0
        matrix[taps - 1 - index, index] = 1.0
    return matrix


def linear_phase_response_matrix(taps: int, angular_frequencies: np.ndarray) -> np.ndarray:
    delay = (taps - 1) / 2
    n = np.arange(taps)
    return np.cos(angular_frequencies[:, None] * (n[None, :] - delay))


def normalize_kernel_dc(kernel: np.ndarray) -> np.ndarray:
    kernel_sum = np.sum(kernel)
    if abs(kernel_sum) < 1e-15:
        raise ValueError("FIR kernel has near-zero DC gain")
    return kernel / kernel_sum


def fir_group_delay_dc_output_samples(kernel: np.ndarray) -> float:
    return float(np.sum(np.arange(len(kernel)) * kernel) / np.sum(kernel))


def kernel_to_python(
    *,
    kernel: np.ndarray,
    f_s_cic: float,
    R_cic: int,
    N_cic: int,
    M_cic: int,
    compensation_name: str | None,
) -> str:
    params = (
        f"f_s_cic={f_s_cic:.12g}, R_cic={R_cic}, N_cic={N_cic}, M_cic={M_cic}, "
        f"fir={compensation_name!r}, approximation FIR order={len(kernel) - 1} taps={len(kernel)}"
    )
    kernel_text = ", ".join(f"{x:+.9e}" for x in kernel)
    border = "#" + '-' * 80
    return "\n".join((
        border,
        f"# FIR kernel approximating the CIC decimator specified below (generated using {sys.argv[0]})",
        f"# {params}",
        f"kernel = [{kernel_text}]",
        border,
    ))


def resolve_fir_kernel(fir_name: str | None) -> tuple[str | None, np.ndarray | None]:
    if fir_name is None:
        return None, None
    if not fir_name.endswith(".fir.memb"):
        fir_name += ".fir.memb"
    fir_kernel_file = Path(fir_name)
    if not fir_kernel_file.exists():
        fir_kernel_file = next(Path(__file__).parent.rglob(fir_name), None)
    if fir_kernel_file is None:
        fir_kernel_file = next((path for path in Path(".").rglob(fir_name) if "build" not in path.parts), None)
    if fir_kernel_file is None:
        raise FileNotFoundError(fir_name)
    _, fir_kernel = fir_kernel_from_verilog_fixpoint(fir_kernel_file)
    return fir_kernel_file.name, normalize_kernel_dc(fir_kernel)


def plot_response(
    *,
    f_s_cic: float,
    R_cic: int,
    M_cic: int,
    N_cic: int,
    kernel: np.ndarray,
    compensation_kernel: np.ndarray | None,
    compensation_name: str | None,
    out: Path,
) -> None:
    f_s_fir = cic_output_frequency(R_cic, f_s_cic)
    w_fir, h_fir = freqz(kernel, worN=FREQUENCY_SAMPLES, fs=f_s_fir)
    h_reference = cic_response_normalized(
        frequencies=w_fir,
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
    )
    if compensation_kernel is not None:
        _, h_compensation = freqz(compensation_kernel, worN=2 * math.pi * w_fir / f_s_fir)
        h_reference *= np.abs(h_compensation)

    tau_cic_output_samples = cic_group_delay_output_samples(R_cic=R_cic, M_cic=M_cic, N_cic=N_cic)
    tau_compensation_output_samples = 0.0 if compensation_kernel is None else fir_group_delay_dc_output_samples(
        compensation_kernel
    )
    tau_reference_output_samples = tau_cic_output_samples + tau_compensation_output_samples
    tau_fir_output_samples = fir_group_delay_dc_output_samples(kernel)

    fig, ax = plt.subplots(figsize=(15, 10))
    label = "CIC" if compensation_kernel is None else "CIC+FIR reference"
    ax.plot(w_fir * 1e-3, np.abs(h_reference), color="b", linestyle="-", linewidth=1.0, label=label)
    ax.plot(w_fir * 1e-3, np.abs(h_fir), color="r", linestyle="-", linewidth=1.0, label="FIR approximation")
    ax.set_xlabel("Frequency [kHz]")
    ax.set_ylabel("Magnitude [1]")
    ax.grid(True, which="both")
    ax.legend(loc="best")
    ax.minorticks_on()

    title = f"{f_s_cic=:e} {R_cic=} {M_cic=} {N_cic=} taps={len(kernel)}"
    if compensation_name is not None:
        title += f" comp_fir={compensation_name!r}"
    title += f" tau_ref={tau_reference_output_samples:.4f} tau_fir={tau_fir_output_samples:.4f} output samples"
    ax.set_title(title)
    plt.tight_layout()
    fig.savefig(out, dpi=192, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    f_s_cic, R_cic = float(sys.argv[1]), int(sys.argv[2], 0)
    N_cic = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    M_cic = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    compensation_name, compensation_kernel = resolve_fir_kernel(sys.argv[5] if len(sys.argv) > 5 else None)

    kernel = cic_approx_fir_kernel(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        compensation_kernel=compensation_kernel,
    )
    f_s_fir = cic_output_frequency(R_cic, f_s_cic)
    tau_cic_output_samples = cic_group_delay_output_samples(R_cic=R_cic, M_cic=M_cic, N_cic=N_cic)
    tau_compensation_output_samples = 0.0 if compensation_kernel is None else fir_group_delay_dc_output_samples(
        compensation_kernel
    )
    tau_reference_output_samples = tau_cic_output_samples + tau_compensation_output_samples
    tau_fir_output_samples = fir_group_delay_dc_output_samples(kernel)
    N_fir = len(kernel) - 1

    print(f"{f_s_cic=} {R_cic=} {N_cic=} {M_cic=} fir={compensation_name!r}")
    print(f"{f_s_fir=}")
    print(f"tau_cic={tau_cic_output_samples:.12g} output samples, {tau_cic_output_samples / f_s_fir:.12g} seconds")
    print(
        f"tau_compensation={tau_compensation_output_samples:.12g} output samples, "
        f"{tau_compensation_output_samples / f_s_fir:.12g} seconds"
    )
    print(
        f"tau_reference={tau_reference_output_samples:.12g} output samples, "
        f"{tau_reference_output_samples / f_s_fir:.12g} seconds"
    )
    print(f"tau_fir={tau_fir_output_samples:.12g} output samples, {tau_fir_output_samples / f_s_fir:.12g} seconds")
    print(f"sum={np.sum(kernel):.12g}")
    print()
    print(
        kernel_to_python(
            kernel=kernel,
            f_s_cic=f_s_cic,
            R_cic=R_cic,
            N_cic=N_cic,
            M_cic=M_cic,
            compensation_name=compensation_name,
        )
    )
    print()

    title = f"{f_s_cic=:.0f},{R_cic=},{N_cic=},{M_cic=},fir={compensation_name}"
    out = Path(f"cic_approx_fir.{title}.png")
    plot_response(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        kernel=kernel,
        compensation_kernel=compensation_kernel,
        compensation_name=compensation_name,
        out=out,
    )
    print(out)


if __name__ == "__main__":
    main()
