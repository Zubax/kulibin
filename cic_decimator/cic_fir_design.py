#!/usr/bin/env python3

"""
A script for designing FIR compensation filters for CIC decimators.

For background, see the Verilog implementation modules and the linked references.
PyFDA can be used to produce additional plots, e.g., phase delay.
"""

import math
from pathlib import Path
from hashlib import sha256

import numpy as np
from scipy.signal import freqz, firwin2
import matplotlib.pyplot as plt

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
    DC up to about f_pass_max, and then drops steeply.
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
    # Construct visualizations.
    plot_cic_fir(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        fir_kernel_real=kernel,
        fir_kernel_quantized=np.array([from_fixpoint(Q_kernel, to_fixpoint_bin(Q_kernel, x)) for x in kernel]),
        title=f"{f_pass_max=:e} {N_fir=} q{Q_kernel[0]}.{Q_kernel[1]}",
        out=f"{stem}.response.png",
    )
    return stem


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
    roll-off immediately after DC. This is intended for unbiasing signals before an integration stage.
    This is done with an ordinary sinc low-pass FIR kernel.
    """
    f_s_fir = cic_output_frequency(R_cic, f_s_cic)
    f_c = 0
    L = N_fir + 1
    h = np.sinc(2 * f_c / f_s_fir * (np.arange(L) - (L - 1) / 2)) * np.blackman(L)
    h /= np.sum(h)  # Ensure unity DC gain.
    # Export the designed kernel for later use in Verilog.
    stem = fir_kernel_to_verilog_fixpoint(Q_kernel, h)
    # Construct visualizations.
    plot_cic_fir(
        f_s_cic=f_s_cic,
        R_cic=R_cic,
        M_cic=M_cic,
        N_cic=N_cic,
        fir_kernel_real=h,
        fir_kernel_quantized=np.array([from_fixpoint(Q_kernel, to_fixpoint_bin(Q_kernel, x)) for x in h]),
        title=f"{N_fir=} q{Q_kernel[0]}.{Q_kernel[1]}",
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


def fir_kernel_to_verilog_fixpoint(q: tuple[int, int], kernel: np.ndarray) -> str:
    """
    Exports FIR coefficients into a Verilog memb file in the specified fixed point q-format that can be read
    into synthesized logic via $readmemb(). We use binary instead of hex exports because they are single-bit-granular,
    which is convenient with q-formats that have the total bit counts that are not multiples of 4 bits.

    Kernel fixpoint precision affects frequency response error; input precision sets the noise floor. More coeff bits
    won't raise SNR beyond the input's quantization limit, but they do preserve stopband attenuation and passband
    ripple.

    The stem of the file is the 128 MSb (16 MSB) of the SHA-256 of the binary coefficients separated with newlines `n.
    The stem is returned.
    """
    # Analysis for the information comment
    w, h  = freqz(kernel, fs=1)
    freqs = np.linspace(0.0, 0.5, 21)
    gains = np.interp(freqs, w, np.abs(h))

    comment = f"""\
// Generated using {Path(__file__).name}.
//
// Normalized frequency response with f_s=1:
//  f [Hz]: {' '.join(f'{x:.4f}' for x in freqs)}
//  G [1]:  {' '.join(f'{x:.4f}' for x in gains)}
//
// {len(kernel)} FIR coefficients in q{q[0]}.{q[1]} fixpoint format.
"""
    fixpoints = [to_fixpoint_bin(q, x) for x in kernel]
    stem = sha256("\n".join(fixpoints).encode()).hexdigest()[:16]
    contents = comment + "\n" + "\n".join(f"{fix}  // {flt:+.12e}" for fix, flt in zip(fixpoints, kernel))
    Path(f"{stem}.fir.memb").write_text(contents)
    return stem


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
    ax2.plot(w_fir_q, np.abs(h_tot_q), label="total quantized")
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


if __name__ == "__main__":
    # Sigma-delta ADC front-end.
    f_s_sdadc = 20e6
    R_cic_sdadc = 64
    design_cic_compensation_fir(
        f_s_cic=f_s_sdadc,
        R_cic=R_cic_sdadc,
        M_cic=1,
        N_cic=3,
        N_fir=12,
        f_pass_max=60e3,
        Q_kernel=(1, 16),
    )
    # There was an attempt to use a separate CIC+FIR stage for DC bias removal, but it is not an adequate solution
    # because the large group delay in the CIC+FIR stage causes instability at low frequencies.
    # We have since switched to a very simple IIR which works well.
