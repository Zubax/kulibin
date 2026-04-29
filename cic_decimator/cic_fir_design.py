#!/usr/bin/env python3

"""
A script for designing FIR compensation filters for CIC decimators, and analysis of the combined CIC+FIR filter.
For background, see the Verilog implementation modules and the linked references.
PyFDA can be used to produce additional plots, e.g., phase delay.
"""

import math
import sys
from pathlib import Path

import numpy as np
from scipy.signal import freqz, firwin2
import matplotlib.pyplot as plt

sys.path.append(str(Path(__file__).parent.parent / "fir"))
from fir import fir_kernel_to_verilog_fixpoint, fir_design_sinc
from fixpoint import to_fixpoint_bin, from_fixpoint


def design_cic_compensation_fir(
    *,
    f_s_cic: float,
    R_cic: int,
    M_cic: int,
    N_cic: int,
    N_fir: int,
    f_pass_max: float,
    Q_kernel: tuple[int, int] = (1, 16),  # (integer bits, fractional bits)
) -> str:
    """
    Given a CIC filter parameters and the desired low-pass band, produces the compensation FIR filter kernel that
    mitigates the CIC passband droop and introduces a steeper roll-off. The resulting total gain is very flat from
    DC up to about f_pass_max, and then drops steeply. The FIR is fixed-point Q-format as specified.
    Returns the stem of the generated files.
    """
    f_s_fir = cic_output_frequency(R_cic, f_s_cic)
    kernel = cic_fir_kernel(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        N_fir=N_fir,
        f_pass_max=f_pass_max,
        f_stop_min=f_s_fir * 0.5,
    )
    print("FIR kernel before quantization:", *(f"{x:+.3e}" for x in kernel))
    # Export the designed kernel for later use in Verilog.
    stem = fir_kernel_to_verilog_fixpoint(Q_kernel, kernel)
    # Compute the group delay.
    tau_cic, tau_fir = cic_fir_group_delay(f_s_cic=f_s_cic, R_cic=R_cic, N_cic=N_cic, M_cic=M_cic, N_fir=N_fir)
    tau_title = f"τ_cic={tau_cic*1e6:.1f}μs τ_fir={tau_fir*1e6:.1f}μs τ_total={(tau_cic + tau_fir)*1e6:.1f}μs"
    # Construct visualizations.
    plot_cic_fir(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        fir_kernel_real=kernel,
        fir_kernel_quantized=np.array([from_fixpoint(Q_kernel, to_fixpoint_bin(Q_kernel, x)) for x in kernel]),
        title=f"{f_pass_max=:e} {N_fir=} {tau_title} q{Q_kernel[0]}.{Q_kernel[1]}",
        out=f"{stem}.response.png",
    )
    return stem


def cic_fir_kernel(
    *,
    f_s_cic: float,     # Input sample rate at the CIC input; the output is f_s_fir = f_s_cic / R
    R_cic: int,
    M_cic: int,
    N_cic: int,
    N_fir: int,         # FIR order. Prefer smaller to reduce group delay. Odd N result in zero gain at Nyquist.
    f_pass_max: float,  # Max passband frequency. Ideally, we want constant gain from DC to this frequency.
    f_stop_min: float,  # End of the transition band.
) -> np.ndarray:
    """
    Given the parameters of the CIC filter and the FIR filter order, designs the FIR kernel that compensates the
    CIC passband droop and has the specified passband and stopband edges.
    Returns the kernel with (N_fir+1) real taps.
    """
    f_s_fir = cic_output_frequency(R_cic, f_s_cic)
    G_cic = cic_gain(R=R_cic, M=M_cic, N=N_cic, f=0)  # CIC DC gain
    output_bits = 2 + math.ceil(math.log2(G_cic))  # Plus the sign bit
    print(f"CIC DC gain {G_cic} requires {output_bits}-bit output incl. sign bit")
    # Design the FIR kernel such that the total passband gain of the combined filter is flat one.
    # For that, sample the actual gain of the CIC in the passband, and use the reciprocal as the FIR gain.
    f_pass_samples = np.linspace(0, f_pass_max, 1000)
    h_pass_samples = 1 / np.array([
        cic_gain(R=R_cic, M=M_cic, N=N_cic, f=x, f_s_in=f_s_cic) / G_cic
        for x in f_pass_samples
    ])
    print("f_pass:", *f_pass_samples[:10])
    print("h_pass:", *h_pass_samples[:10])
    # firwin2 tracks the passband gain error poorly which results in a gain error.
    # To mitigate it, we scale the kernel leveraging the fact that the sum of its coefficients is the FIR DC gain.
    kernel = firwin2(
        N_fir + 1,
        np.append(f_pass_samples, [min(f_stop_min, f_s_fir * 0.4999), f_s_fir * 0.5]),
        np.append(h_pass_samples, [0, 0]),
        window="hamming",  # Hamming offers better passband ripple
        antisymmetric=False,
        nfreqs=4097,
        fs=f_s_fir,
    )
    return kernel / sum(kernel)  # Ensure unity DC gain.


def design_dc_removal_fir(
    *,
    f_s_cic: float,
    R_cic: int,
    M_cic: int,
    N_cic: int,
    N_fir: int,
    Q_kernel: tuple[int, int] = (1, 16),  # (integer bits, fractional bits)
) -> str:
    """
    This is similar to the compensation filter design, but the FIR is optimized to pass only DC and have a very steep
    roll-off immediately after DC. This is done with an ordinary sinc low-pass FIR kernel.
    This filter introduces a very large group delay which may limit its utility.
    """
    stem, fir_kernel = fir_design_sinc(
        f_s=cic_output_frequency(R_cic, f_s_cic),
        f_c=0,
        N=N_fir,
        kind="lpf",
        Q_kernel=Q_kernel,
    )
    plot_cic_fir(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        fir_kernel_real=fir_kernel,
        fir_kernel_quantized=np.array([from_fixpoint(Q_kernel, to_fixpoint_bin(Q_kernel, x)) for x in fir_kernel]),
        title=f"{N_fir=} q{Q_kernel[0]}.{Q_kernel[1]}",
        out=f"{stem}.response.png",
    )
    return stem


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


def cic_gain(*, R, M, N, f, f_s_in = 1) -> float:
    """
    The gain of a CIC decimator filter at a given frequency f with the input sampling rate f_s_in.
    """
    if abs(f) < 1e-6:  # DC gain requires a special case due to singularity
        return (R*M)**N
    omega = 2 * math.pi * f / f_s_in  # Angular frequency normalized for unity sampling frequency
    # The magnitude can be derived from the z-domain transfer function.
    return abs(math.sin(R * M * omega / 2) / math.sin(omega/2)) ** N


def cic_output_frequency(R, f_s_in) -> float:
    return f_s_in / R


def plot_cic_fir(
    *,
    f_s_cic: float,
    R_cic: int,
    M_cic: int,
    N_cic: int,
    fir_kernel_real: np.ndarray,
    fir_kernel_quantized: np.ndarray,
    title: str,
    out: str = "response.png",
) -> None:
    G_cic = cic_gain(R=R_cic, M=M_cic, N=N_cic, f=0)
    print(f"CIC gain {G_cic} => bit growth {math.ceil(math.log2(G_cic))}")
    f_s_fir = cic_output_frequency(R_cic, f_s_cic)
    w_cic = np.linspace(0, 1, 1000) * f_s_fir
    h_cic = np.array([
        cic_gain(R=R_cic, M=M_cic, N=N_cic, f=x, f_s_in=f_s_cic) / G_cic
        for x in w_cic
    ])
    w_fir_r, h_fir_r = freqz(fir_kernel_real,      whole=True, fs=f_s_fir)
    w_fir_q, h_fir_q = freqz(fir_kernel_quantized, whole=True, fs=f_s_fir)
    # Combined frequency response
    h_tot_r = h_fir_r * np.interp(w_fir_r, w_cic, h_cic)
    h_tot_q = h_fir_q * np.interp(w_fir_q, w_cic, h_cic)

    fig, (ax1, ax2) = plt.subplots(2, 1, sharex=True, figsize=(15, 10), gridspec_kw={"height_ratios": [4, 1]})

    # Full response
    ax1.plot(w_fir_q,  np.abs(h_fir_q), color='r', linestyle='-', label="FIR quantized")
    ax1.plot(w_fir_r,  np.abs(h_fir_r), color='r', linestyle=':', label="FIR real")
    ax1.plot(w_cic,    np.abs(h_cic),   color='b', linestyle='-', label="CIC")
    ax1.plot(w_fir_q,  np.abs(h_tot_q), color='k', linestyle='-', label="total quantized")
    ax1.plot(w_fir_r,  np.abs(h_tot_r), color='k', linestyle=':', label="total real")
    ax1.set_ylabel("Magnitude [1]")
    ax1.grid(True, which='both')
    ax1.legend(loc="best")
    ax1.minorticks_on()

    # Zoomed passband
    passband_zoom_y = 1.5e-3
    ax2.plot(w_fir_q, np.abs(h_tot_q), color='k', label="total quantized")
    ax2.plot(w_cic, np.abs(h_cic), color='b', label="CIC")
    ax2.axhline(1.0, linewidth=1, linestyle="--")
    ax2.set_ylim(1-passband_zoom_y, 1+passband_zoom_y)
    ax2.set_xlabel("Frequency [Hz]")
    ax2.set_ylabel("Gain [1]")
    ax2.minorticks_on()
    ax2.grid(True)
    ax2.legend(loc="best")

    title = f"{f_s_cic=:e} {R_cic=} {M_cic=} {N_cic=} {title}"
    plt.title(title)
    plt.tight_layout()
    #plt.show()
    fig.savefig(out, dpi=192, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    def cicfir(N_fir: int, f_pass_max: float) -> str:
        try:
            return design_cic_compensation_fir(
                f_s_cic=20e6,
                R_cic=64,
                M_cic=1,
                N_cic=3,
                N_fir=N_fir,
                f_pass_max=f_pass_max,
                Q_kernel=(1, 15),
            )
        except Exception as ex:
            print("Error:", ex)
            return None
    print(cicfir(5, 150e3))
    print(cicfir(12, 60e3))

    if False:
        stem = design_dc_removal_fir(
            f_s_cic=20e6,
            R_cic=64,
            M_cic=1,
            N_cic=3,
            N_fir=30,
        )
        print(stem)


if __name__ == "__main__":
    main()
