#!/usr/bin/env python3
"""Test inputs for zkf_const. Source of truth shared by gen_zkf_const_wrap.py and test_const.py.

Every value in FINITE_VALUES must fit in the smallest format covered by the test matrix (w3_m4:
|v| in [0.25, 15)); larger or smaller magnitudes would trip STATUS_OVERFLOW or STATUS_UNDERFLOW
at elaboration which halts the build. After editing this list, regenerate zkf_const_wrap.v by
running ``python3 float/tb/gen_zkf_const_wrap.py`` (or ``make gen-const-wrap``).
"""

from __future__ import annotations

import math


# Curated finite test inputs. Categorized to exercise specific branches of zkf_const at
# elaboration time. The reference packer in zkf_model.round_fraction_to_zkf handles every
# value uniformly, so the categories below document intent rather than gating behaviour.
FINITE_VALUES: list[float] = [
    # ---- Exact powers of two, both signs, eu in [-2, 3]. Stresses f_floor_log2's correction
    #      against $ln's rounded result at exact-power-of-two inputs.
    0.25, 0.5, 1.0, 2.0, 4.0, 8.0,
    -0.25, -0.5, -1.0, -2.0, -4.0, -8.0,

    # ---- Math constants and irrationals; non-trivial mantissa bit patterns at every WMAN.
    math.pi, -math.pi,
    math.e, -math.e,
    math.sqrt(2), -math.sqrt(2),
    math.sqrt(3),
    math.sqrt(5),
    math.sqrt(7),
    math.sqrt(11),
    math.sqrt(13),
    (1 + math.sqrt(5)) / 2,
    math.log(2), -math.log(2),
    math.log(3),
    math.log(5),
    math.log(7),
    math.log(11),
    math.log(13),
    math.log10(2),
    math.log10(3),
    math.log10(5),
    math.log10(7),
    math.exp(0.5),
    1.0 / math.pi,
    1.0 / math.e,

    # ---- Simple fractions in [0.25, 1.0). Various denominators so the rounded significand
    #      hits a wide range of bit patterns at every tested WMAN.
    1 / 3, 2 / 3, -1 / 3, -2 / 3,
    2 / 5, 3 / 5, 4 / 5, -3 / 5, -4 / 5,
    5 / 6, -5 / 6,
    2 / 7, 3 / 7, 4 / 7, 5 / 7, 6 / 7,
    3 / 8, 5 / 8, 7 / 8, -3 / 8, -5 / 8,
    4 / 9, 5 / 9, 7 / 9, 8 / 9,
    3 / 10, 7 / 10, 9 / 10,
    3 / 11, 5 / 11, 7 / 11, 10 / 11,
    7 / 12, 11 / 12,
    4 / 13, 8 / 13, 12 / 13,

    # ---- Just-below powers of two. At small WMAN these round up; at WMAN=4 several trigger
    #      the f_real_to_uint -> renormalize-up path.
    0.96875, 0.984375,
    0.99, 0.999, 0.9999,
    1.99, 1.999, 1.9999,
    3.99, 3.999, 3.9999,
    7.99, 7.999, 7.9999,
    14.9, 14.99, 14.999, 14.9999,
    -0.99, -1.99, -3.99, -7.99, -14.99,

    # ---- Just-above powers of two. Exercise the f_floor_log2 up-correction.
    0.26, 0.27, 0.51, 0.501,
    1.001, 1.01, 1.1,
    2.001, 2.01,
    4.001, 4.01,
    8.001, 8.01,
    -0.51, -1.001, -2.001, -4.001, -8.001,

    # ---- Halfway-exact RTNE cases at WMAN=4 (eu=0). The kept significand sits on an exact
    #      tie boundary; even/odd LSB selects the rounding direction.
    1.0625,            # m_real=8.5,  fl=8  even -> stay  (decoded 1.0)
    1.0624,            # just below tie -> round down
    1.0626,            # just above tie -> round up
    1.1875,            # m_real=9.5,  fl=9  odd  -> round up to 10 (decoded 1.25)
    1.3125,            # m_real=10.5, fl=10 even -> stay (decoded 1.25)
    1.4375,            # m_real=11.5, fl=11 odd  -> round up to 12 (decoded 1.5)
    1.5625,            # m_real=12.5, fl=12 even -> stay
    1.6875,            # m_real=13.5, fl=13 odd  -> round up
    1.8125,            # m_real=14.5, fl=14 even -> stay

    # ---- Halfway-exact RTNE cases at WMAN=4 spread across other eu values so the rounding
    #      branches fire with a non-zero unbiased exponent.
    2.125, 2.375, 2.625, 2.875, 3.125, 3.375, 3.625,
    0.53125, 0.59375, 0.65625, 0.71875, 0.78125, 0.84375, 0.90625,
    0.265625, 0.296875, 0.328125, 0.359375, 0.390625, 0.421875, 0.453125, 0.484375,

    # ---- Renormalization triggers across multiple eu values. Each value rounds up to the
    #      next power of two at WMAN=4, which sets sig_int[WMAN] and bumps the exponent.
    1.9375, 1.96875, 1.984375,        # eu=0 -> 2.0
    3.875, 3.96875, 3.984375,         # eu=1 -> 4.0
    7.875, 7.96875, 7.984375,         # eu=2 -> 8.0
    -1.9375, -3.875, -7.875,

    # ---- Round-half-down sanity (diff strictly less than 0.5 at small WMAN).
    1.0624, 1.1874, 1.3124, 1.5624,

    # ---- Round-half-up sanity (diff strictly greater than 0.5 at small WMAN).
    1.0626, 1.1876, 1.3126, 1.5626,

    # ---- Generic single-decimal values for variety across magnitudes and signs.
    0.30, 0.32, 0.35, 0.40, 0.42, 0.45, 0.48,
    0.52, 0.55, 0.60, 0.66, 0.70, 0.77, 0.80, 0.88,
    1.10, 1.20, 1.30, 1.40, 1.50, 1.60, 1.70, 1.80, 1.90,
    2.10, 2.30, 2.50, 2.70, 2.90,
    3.10, 3.30, 3.50, 3.70,
    4.50, 5.00, 5.50, 6.00, 6.50, 7.00, 7.50,
    9.00, 10.0, 11.0, 12.0, 13.0, 14.0,
    -1.10, -1.30, -1.70, -2.30, -2.70,
    -3.30, -3.70, -5.50, -7.50, -10.0, -13.0,
]


# Values fed to the INF parameter (VALUE is irrelevant in INF mode). The sign of the result
# follows the sign of INF; magnitude does not matter, so the list also covers non-canonical
# values like +1000 to confirm the INF != 0 check is a plain non-zero test.
INF_SIGNS: list[int] = [+1, +2, +7, +1000, -1, -2, -7, -1000]


def _dedup_in_order(values: list[float]) -> list[float]:
    """Drop duplicates while preserving first-seen order; keys are bit-exact float values."""
    seen: set[float] = set()
    unique: list[float] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        unique.append(value)
    return unique


FINITE_VALUES = _dedup_in_order(FINITE_VALUES)
