#!/usr/bin/env python3

"""
See iir1_lpf.v and iir1_hpf.v for the details.
This script simply visualizes the response.
"""

import numpy as np
from scipy.signal import freqz
import matplotlib.pyplot as plt

# Filter and sampling parameters.
f_s = 312500
k = 13
alpha = 2**-int(k)
f_plot_max = 20
freqs = np.linspace(0, f_plot_max, 1000)

# General IIR coefficients. Given the difference form:
#   y[n] = y[n-1] + alpha (x[n] - y[n-1])
# Rearrange into standard form:
#   y[n] - (1-alpha) y[n-1] = alpha x[n]
ba_lpf = [alpha, 0], [1, -(1-alpha)]

# The coefficients for the HPF defined as the DC subtractor: HPF(z) = 1-LPF(z)
# Derivation omitted.
ba_hpf = [1-alpha, -(1-alpha)], [1, -(1-alpha)]

# The DC bias leak of the online_integrator. Refer to the Verilog module for details and derivations.
intg_leak = k
intg_k = 2**-int(intg_leak)
ba_intg_leak = [+1, -1], [+1, -(1-intg_k)]

# PLOTTING
fig, (ax1, ax2) = plt.subplots(2, 1, sharex=True, figsize=(10, 10), gridspec_kw={"height_ratios": [1, 1]})
def setup_grid(ax):
    ax.minorticks_on()
    ax.grid(True, which='major', linewidth=0.5)
    ax.grid(True, which='minor', linestyle=':', linewidth=0.3)

# Frequency response.
f, H_lpf = freqz(*ba_lpf, worN=freqs, fs=f_s)
ax1.plot(f, np.abs(H_lpf), label="LPF")
f, H_hpf = freqz(*ba_hpf, worN=freqs, fs=f_s)
ax1.plot(f, np.abs(H_hpf), label="HPF")
f, H_intg_leak = freqz(*ba_intg_leak, worN=freqs, fs=f_s)
ax1.plot(f, np.abs(H_intg_leak), label="online_integrator leak", linestyle=":")

ax1.set_xlabel('Frequency [hertz]')
ax1.set_ylabel('Magnitude [1]')
ax1.set_xlim([0, f_plot_max])
setup_grid(ax1)
ax1.legend()

# Phase delay.
def get_phase_delay(f, H):
    phase = np.unwrap(np.angle(H))
    f_nz = f > 0
    tau_p_second = np.full_like(f, np.nan, dtype=float)
    tau_p_second[f_nz] = -phase[f_nz] / (2 * np.pi * f[f_nz])
    return tau_p_second

tau_p_second_lpf = get_phase_delay(f, H_lpf)
tau_p_second_hpf = get_phase_delay(f, H_hpf)
ax2.plot(f, tau_p_second_lpf, label="tau_p_lpf")
ax2.plot(f, tau_p_second_hpf, label="tau_p_hpf")
ax2.set_xlabel('Frequency [hertz]')
ax2.set_ylabel('Phase delay [second]')
ax2.set_ylim([-5e-3, +20e-3])
setup_grid(ax2)
ax2.legend()

fig.suptitle(f"{f_s=} {k=}")
fig.tight_layout()
fig.savefig("iir.png", dpi=150, bbox_inches="tight")
