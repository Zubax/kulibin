#!/usr/bin/env python3
"""
Utilities for basic analysis of a CIC decimation filter.
Single-bit inputs, which are common in sigma-delta ADCs, are represented as a 2-bit signed integer:
zero maps to +1, one maps to -1 (values 0 and -2 are unused/inadmissible).
"""

import math
import sympy as sp


def cic_gain(*, R, M, N, f, f_s_in = 1) -> sp.Expr:
    """
    The gain of a CIC decimator filter at a given frequency f with the input sampling rate f_s_in.
    """
    omega = 2 * sp.pi * f / f_s_in  # Angular frequency normalized for unity sampling frequency
    # The magnitude can be derived from the z-domain transfer function.
    return sp.Pow(sp.Abs(sp.sin(R * M * omega / 2) / sp.sin(omega/2)), N)


def cic_gain_dc(*, R, M, N) -> sp.Expr:
    """
    The DC gain of a CIC decimator filter.
    The generic gain equation is ill-defined at zero frequency, so we use this special form instead.
    """
    return (R*M)**N


def cic_frequency_at_gain(*, R, M, N, gain, f_s_in = 1) -> sp.Float:
    """
    Given a non-normalized gain (typically >>1), find the lowest frequency where it is encountered.
    To use normalized gain, mutiply it by the CIC DC gain.
    """
    f_c = sp.symbols('f_c')
    # The frequency range from DC to f_s_in/R spans the gain from (R*M)**N down to zero.
    bounds = (
        f_s_in * 0.000001 / R,
        f_s_in * 0.999999 / R,
    )
    return sp.nsolve(
        sp.Eq(
            cic_gain(R=R, M=M, N=N, f=f_c, f_s_in=f_s_in),
            gain,
        ),
        bounds,
        solver='bisect',
        verify=False
    )


def cic_output_frequency(R, f_s_in) -> sp.Float:
    return f_s_in / R


def cic_cutoff_frequency(*, R, M, N, f_s_in = 1) -> sp.Float:
    return cic_frequency_at_gain(R=R, M=M, N=N, gain=(1 / sp.sqrt(2)) * cic_gain_dc(R=R, M=M, N=N), f_s_in=f_s_in)


def cic_output_bit_width_signed(input_bit_width=2, /, *, R, M, N) -> sp.Expr:
    if input_bit_width < 2:
        raise ValueError("Signed int cannot be less than 2 bits wide.")
    return sp.ceiling(input_bit_width + sp.log(cic_gain_dc(R=R, M=M, N=N), 2))


def cic_group_delay(f_s_cic, R_cic, N_cic, M_cic):
    tau_cic_input_samples = N_cic * (R_cic * M_cic - 1) / 2
    return tau_cic_input_samples / f_s_cic


def main():
    R, M, N = 64, 1, 3
    f_s_in = 20e6
    res = {
        "W_out": cic_output_bit_width_signed(R=R, M=M, N=N),
        "f_out": cic_output_frequency(R=R, f_s_in=f_s_in),
        "f_c": cic_cutoff_frequency(R=R, M=M, N=N, f_s_in=f_s_in),
        "tau": cic_group_delay(f_s_cic=f_s_in, R_cic=R, N_cic=N, M_cic=M),
    }
    print(f"{R=} {M=} {N=} {f_s_in=}; single-bit signed input: {res}")


if __name__ == "__main__":
   main()
