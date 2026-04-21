#!/usr/bin/env python3

"""
Fixpoint FIR filter utilities.
Fixpoint is specified in the Q-format, with the integer bits including the sign bit.
"""

import sys
from pathlib import Path
from hashlib import sha256
from typing import Literal

import numpy as np
from scipy.signal import freqz
import matplotlib.pyplot as plt

sys.path.append(str(Path(__file__).parent.parent / "numeric"))
from fixpoint import to_fixpoint_bin, from_fixpoint


def fir_design_sinc(
    *,
    f_s: float,
    f_c: float,
    N: int,
    kind: Literal["lpf", "hpf"],
    Q_kernel: tuple[int, int] = (1, 15),
) ->tuple[str, np.ndarray]:
    """
    Design a FIR kernel and store files in the current working directory.
    N is the filter order, one less than the number of taps/coeffs.
    Returns the stem of the file names: Verilog .memb kernel coeffs and a response plot, plus the real kernel.
    """
    if not (0.0 <= f_c < 0.5 * f_s):
        raise ValueError(f"Bad cutoff frequency")

    L = N + 1
    n = np.arange(L)
    m = (L - 1) / 2

    h = np.sinc(2 * f_c / f_s * (n - m)) * np.blackman(L)
    h /= np.sum(h)  # Normalize for unity DC gain.

    if kind == "lpf":
        pass
    elif kind == "hpf":
        if (L % 2) == 0:
            raise ValueError("HPF via spectral inversion requires an odd number of taps; use even N.")
        h = -h
        h[L // 2] += 1.0  # Add discrete-time delta at center tap.
        # Normalize for unity gain at Nyquist.
        nyq_gain = np.sum(h * ((-1.0) ** n))
        h /= nyq_gain
    else:
        raise ValueError(f"Unsupported filter kind: {kind=!r}")

    quantized = np.array([from_fixpoint(Q_kernel, to_fixpoint_bin(Q_kernel, x)) for x in h])
    stem = fir_kernel_to_verilog_fixpoint(Q_kernel, h)
    fir_plot(
        f_s=f_s,
        kernel_real=h,
        kernel_quantized=quantized,
        title=f"{kind.upper()} {N=} q{Q_kernel[0]}.{Q_kernel[1]}",
        out=f"{stem}.response",
    )
    return stem, h


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
    Path(f"{stem}.fir.memb").write_text(contents.strip() + "\n")
    return stem


def fir_plot(*, f_s: float, kernel_real: np.ndarray, kernel_quantized: np.ndarray, title: str, out: str) -> None:
    w_r, h_r = freqz(kernel_real,      whole=True, fs=f_s)
    w_q, h_q = freqz(kernel_quantized, whole=True, fs=f_s)

    fig, ax1 = plt.subplots(figsize=(12, 9))

    # Full response
    ax1.plot(w_q,  np.abs(h_q), color='k', linestyle='-', linewidth=1.0, label="quantized")
    ax1.plot(w_r,  np.abs(h_r), color='r', linestyle=':', linewidth=1.0, label="real")
    ax1.set_ylabel("Magnitude [1]")
    ax1.grid(True, which='both')
    ax1.legend(loc="best")
    ax1.minorticks_on()

    title = f"{title} {f_s=:e}"
    plt.title(title)
    plt.tight_layout()
    #plt.show()
    out = out if out.endswith(".png") or out.endswith(".svg") else f"{out}.png"
    fig.savefig(out, dpi=192, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    print(fir_design_sinc(f_s=156.25e3, f_c=10e3, N=10, kind="lpf")[0])
    print(fir_design_sinc(f_s=156.25e3, f_c=10e3, N=10, kind="hpf")[0])
