#!/usr/bin/env python3

"""
For cross-checking, this script implements the IIR forms used in Verilog in Python, and evaluates their characteristics.
"""

import numpy as np
import matplotlib.pyplot as plt
from scipy.signal import lfilter


# SIGNAL GENERATION UTILITIES

def cosine_amplitude(
    x: np.ndarray, /, f: float, f_s: float, *, window: str | None = "hann", remove_mean: bool = True
) -> np.ndarray:
    """
    Estimates the amplitude and phase of a given frequency cosine wave in the signal.
    Amplitude corrected for the window coherent gain.
    Returns (amplitude, phase [radian]).
    """
    x = np.asarray(x, dtype=float)
    N = x.size
    if window is None or window == "rect":
        w = np.ones(N)
    elif window == "hann":
        w = np.hanning(N)
    elif window == "hamming":
        w = np.hamming(N)
    else:
        raise ValueError(f"broken window: {window}")
    if f < f_s * 1e-9:  # Special-case low f because the rest is ill-defined for DC
        mu = np.sum(w * x) / np.sum(w)
        return abs(mu), 0.0
    if remove_mean:
        x = x - np.mean(x)
    n = np.arange(N)
    omega = 2*np.pi*f/f_s
    s = np.sum(w * x * np.exp(-1j*omega*n))
    # For a pure tone: s ~ (A/2) sum(w) e^(+j phase)
    cg = np.sum(w)                          # coherent gain
    amp = 2.0 * np.abs(s) / cg              # peak amplitude
    phase = np.angle(s)                     # rad
    return amp, phase


def make_cosine(f: float, f_s: float, a: float = 1.0, *, N: int = 10000) -> tuple[np.ndarray, np.ndarray]:
    """
    Construct time points and harmonic signal samples at the given frequency and amplitude.
    """
    dur = N / f_s
    t = np.linspace(0, dur, N)
    y = np.cos(t * f * np.pi * 2) * a
    return t, y


# SIGNAL PROCESSING FUNCTIONS (DUT)

def iir1_lpf(x: np.ndarray, /, *, k: int) -> np.ndarray:
    """
    Single-pole IIR LPF implementing the following difference equation:

        y[n] = y[n-1] + alpha (x[n] - y[n-1])

    Where alpha = 2^-k, and k is an integer for efficient fixed-point hardware implementation.
    Rearrange into standard form:

        y[n] - (1-alpha) y[n-1] = alpha x[n]

    The IIR coefficients are: b = [alpha, 0]; a = [1, -(1-alpha)]
    """
    x = np.asarray(x, dtype=float)
    if x.ndim != 1:
        raise ValueError("x must be 1D")
    alpha = 2**-k
    a1 = 1.0 - alpha
    y = np.empty_like(x)
    y[0] = x[0]
    for n in range(1, x.size):
        y[n] = a1 * y[n - 1] + alpha * x[n]
    return y


def iir1_lpf_scipy(x: np.ndarray, /, *, k: int) -> np.ndarray:
    """
    Use SciPy instead if the manual difference equation implementation.
    This is supposed to be equivalent.
    """
    x = np.asarray(x, dtype=float)
    alpha = 2**-k
    b, a = [alpha], [1.0, -(1.0 - alpha)]
    zi = [x[0] * (1.0 - alpha)]  # Initial condition: y[0] = x[0]
    y, _ = lfilter(b, a, x, zi=zi)
    return y


def iir1_hpf(x: np.ndarray, /, *, k: int) -> np.ndarray:
    """
    An HPF counterpart defined as HPF(z) = 1-LPF(z).
    """
    return x - iir1_lpf_scipy(x, k=k)


def intg_backward_euler(x: np.ndarray) -> np.ndarray:
    return np.cumsum(x)


def intg_backward_euler_leaky(x: np.ndarray, *, leak: int) -> np.ndarray:
    if not isinstance(leak, int) or leak < 1:
        raise ValueError(f"Invalid leak: {leak}")
    k = 2**-leak
    y = np.empty_like(x)
    y[0] = x[0]
    for n in range(1, x.size):
        y[n] = (1-k) * y[n-1] + x[n]
    return y



# EVALUATION UTILITIES

def sweep_filter_H_phi(
    fun, freqs: np.ndarray, /, f_s: float, *, N: int = int(1e6),
) -> tuple[np.ndarray, np.ndarray]:
    H = np.empty_like(freqs)
    phi = np.empty_like(freqs)
    for i, f in enumerate(freqs):
        t, y = make_cosine(f, f_s, N=N)
        z = fun(y)
        a, p = cosine_amplitude(z, f, f_s)
        H[i], phi[i] = a, p
    return H, phi


def eval_iir1():
    f_s = 312500
    k = 13
    N = int(1e6)
    freqs = np.linspace(1, 20, 101)

    H_lpf, phi_lpf = sweep_filter_H_phi(lambda x: iir1_lpf_scipy(x, k=k), freqs, f_s)
    H_hpf, phi_hpf = sweep_filter_H_phi(lambda x: iir1_hpf(x, k=k), freqs, f_s)

    plt.plot(freqs, H_lpf, label="LPF")
    plt.plot(freqs, H_hpf, label="HPF")
    plt.xlim([0, max(freqs)])
    plt.ylim([0, 1])
    plt.legend()
    plt.grid()
    plt.show()



def eval_intg():
    f_s = 312500
    leak = 14
    N = int(1e6)
    freqs = np.linspace(1, 20, 101)

    H_beu, phi_beu = sweep_filter_H_phi(intg_backward_euler, freqs, f_s)
    H_beu_leak, phi_beu_leak = sweep_filter_H_phi(
        lambda x: intg_backward_euler_leaky(x, leak=leak),
        freqs,
        f_s
    )
    G = H_beu_leak / H_beu

    plt.plot(freqs, G, label="Leak gain, backward Euler")
    plt.xlim(left=0)
    plt.ylim(bottom=0)
    plt.legend()
    plt.grid()
    plt.show()


eval_iir1()
eval_intg()
