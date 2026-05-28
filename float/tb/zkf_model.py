#!/usr/bin/env python3
"""Exact Python model of the Zubax Kulibin floating-point RTL."""

from __future__ import annotations

import math
from dataclasses import dataclass
from fractions import Fraction

import numpy as np


@dataclass(frozen=True)
class ZkfFormat:
    wexp: int
    wman: int

    def __post_init__(self) -> None:
        if self.wexp < 2 or self.wman < 4:
            raise ValueError(f"invalid ZKF format WEXP={self.wexp} WMAN={self.wman}")

    @property
    def wfrac(self) -> int:
        return self.wman - 1

    @property
    def wfull(self) -> int:
        return self.wexp + self.wman

    @property
    def sign_shift(self) -> int:
        return self.wexp + self.wfrac

    @property
    def bias(self) -> int:
        return (1 << (self.wexp - 1)) - 1

    @property
    def exp_inf(self) -> int:
        return (1 << self.wexp) - 1

    @property
    def exp_max_finite(self) -> int:
        return self.exp_inf - 1

    @property
    def frac_mask(self) -> int:
        return (1 << self.wfrac) - 1

    @property
    def min_exp_unbiased(self) -> int:
        return 1 - self.bias

    @property
    def max_exp_unbiased(self) -> int:
        return self.exp_max_finite - self.bias


@dataclass(frozen=True)
class Decoded:
    bits: int
    sign: int
    exp: int
    frac: int
    is_zero: bool
    is_inf: bool
    is_normal: bool


def mask(width: int) -> int:
    return (1 << width) - 1


def unsigned(value: int, width: int) -> int:
    return value & mask(width)


def signed_to_bits(value: int, width: int) -> int:
    return value & mask(width)


def bits_to_signed(value: int, width: int) -> int:
    value &= mask(width)
    sign_bit = 1 << (width - 1)
    return value - (1 << width) if value & sign_bit else value


def signed_range(width: int) -> range:
    return range(-(1 << (width - 1)), 1 << (width - 1))


def pack_bits(fmt: ZkfFormat, sign: int, exp: int, frac: int) -> int:
    return ((sign & 1) << fmt.sign_shift) | ((exp & mask(fmt.wexp)) << fmt.wfrac) | (frac & fmt.frac_mask)


def zero(fmt: ZkfFormat, sign: int = 0) -> int:
    return pack_bits(fmt, sign, 0, 0)


def canonical_inf(fmt: ZkfFormat, sign: int) -> int:
    return pack_bits(fmt, sign, fmt.exp_inf, 0)


def normal(fmt: ZkfFormat, sign: int, exp: int, frac: int) -> int:
    if not 1 <= exp <= fmt.exp_max_finite:
        raise ValueError(f"normal exponent out of range: {exp}")
    if not 0 <= frac <= fmt.frac_mask:
        raise ValueError(f"fraction out of range: {frac}")
    return pack_bits(fmt, sign, exp, frac)


def decode(fmt: ZkfFormat, bits: int) -> Decoded:
    bits &= mask(fmt.wfull)
    sign = (bits >> fmt.sign_shift) & 1
    exp = (bits >> fmt.wfrac) & fmt.exp_inf
    frac = bits & fmt.frac_mask
    return Decoded(
        bits=bits,
        sign=sign,
        exp=exp,
        frac=frac,
        is_zero=exp == 0,
        is_inf=exp == fmt.exp_inf,
        is_normal=0 < exp < fmt.exp_inf,
    )


def significand(fmt: ZkfFormat, bits: int) -> int:
    return (1 << fmt.wfrac) | decode(fmt, bits).frac


def pow2_fraction(exp: int) -> Fraction:
    return Fraction(1 << exp, 1) if exp >= 0 else Fraction(1, 1 << -exp)


def floor_log2_fraction(value: Fraction) -> int:
    if value <= 0:
        raise ValueError("log2 is defined for positive values only")
    exp = value.numerator.bit_length() - value.denominator.bit_length()
    while pow2_fraction(exp + 1) <= value:
        exp += 1
    while pow2_fraction(exp) > value:
        exp -= 1
    return exp


def round_fraction_to_zkf(fmt: ZkfFormat, sign: int, value: Fraction) -> int:
    if value <= 0:
        return zero(fmt)

    exp_unbiased = floor_log2_fraction(value)
    if exp_unbiased < fmt.min_exp_unbiased:
        return normal(fmt, sign, 1, 0) if value >= pow2_fraction(fmt.min_exp_unbiased - 1) else zero(fmt)

    scaled = value / pow2_fraction(exp_unbiased) * (1 << fmt.wfrac)
    quotient = scaled.numerator // scaled.denominator
    remainder = scaled.numerator % scaled.denominator

    increment = (2 * remainder) > scaled.denominator
    increment = increment or ((2 * remainder) == scaled.denominator and (quotient & 1) != 0)
    if increment:
        quotient += 1

    if quotient >= (1 << fmt.wman):
        quotient >>= 1
        exp_unbiased += 1

    if exp_unbiased > fmt.max_exp_unbiased:
        return canonical_inf(fmt, sign)

    return normal(fmt, sign, exp_unbiased + fmt.bias, quotient & fmt.frac_mask)


def pack_reference(
    fmt: ZkfFormat,
    sign: int,
    force_zero: int,
    force_inf: int,
    exp_unbiased: int,
    significand_value: int,
    guard: int,
    round_bit: int,
    sticky: int,
) -> int:
    exp_biased = exp_unbiased + fmt.bias
    exp_underflow_zero = exp_unbiased < (fmt.min_exp_unbiased - 1)
    exp_one_below_min = exp_unbiased == (fmt.min_exp_unbiased - 1)
    exp_overflow = exp_unbiased > fmt.max_exp_unbiased

    round_increment = bool(guard and (round_bit or sticky or (significand_value & 1)))
    rounded_ext = (significand_value & mask(fmt.wman)) + (1 if round_increment else 0)
    round_carry = (rounded_ext >> fmt.wman) & 1
    rounded_significand = (rounded_ext >> 1) if round_carry else (rounded_ext & mask(fmt.wman))
    exp_round_overflow = (exp_biased == fmt.exp_max_finite) and bool(round_carry)
    infinity = bool(force_inf or exp_overflow or exp_round_overflow)

    result_zero = bool(force_zero or ((not force_inf) and exp_underflow_zero))
    result_infinity = (not result_zero) and infinity
    result_min_normal = (not result_zero) and (not result_infinity) and (not force_inf) and exp_one_below_min

    if result_zero:
        return zero(fmt)
    if result_infinity:
        return canonical_inf(fmt, sign)
    if result_min_normal:
        return normal(fmt, sign, 1, 0)

    exp_rounded = (exp_biased + round_carry) & mask(fmt.wexp)
    return pack_bits(fmt, sign, exp_rounded, rounded_significand & fmt.frac_mask)


def pack_from_mag_scale(
    fmt: ZkfFormat,
    sign: int,
    mag: int,
    scale: int,
) -> tuple[int, int, int, int, int, int, int]:
    """Map legacy pack wrapper-style inputs to direct _zkf_pack inputs."""

    if mag == 0:
        return sign & 1, 1, 0, scale, 0, 0, 0

    log2_mag = mag.bit_length() - 1
    exp_unbiased = scale + log2_mag
    aligned = (mag << (fmt.wman + 1)) >> log2_mag
    significand_value = (aligned >> 2) & mask(fmt.wman)
    guard = (aligned >> 1) & 1
    round_bit = aligned & 1

    sticky_width = log2_mag - fmt.wman - 1
    sticky = 0
    if sticky_width > 0:
        sticky = 1 if (mag & mask(sticky_width)) != 0 else 0

    return sign & 1, 0, 0, exp_unbiased, significand_value, guard, round_bit | (sticky << 1)


def pack_from_mag_scale_case(
    fmt: ZkfFormat,
    sign: int,
    mag: int,
    scale: int,
) -> tuple[int, int, int, int, int, int, int, int]:
    sign, force_zero, force_inf, exp_unbiased, significand_value, guard, round_sticky = pack_from_mag_scale(
        fmt,
        sign,
        mag,
        scale,
    )
    return (
        sign,
        force_zero,
        force_inf,
        exp_unbiased,
        significand_value,
        guard,
        round_sticky & 1,
        (round_sticky >> 1) & 1,
    )


def _sticky_below(value: int, high_bit: int) -> int:
    if high_bit < 0:
        return 0
    return 1 if (value & mask(high_bit + 1)) != 0 else 0


def mul_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> int:
    a = decode(fmt, a_bits)
    b = decode(fmt, b_bits)
    result_zero = a.is_zero or b.is_zero
    result_inf = (not result_zero) and (a.is_inf or b.is_inf)

    product = significand(fmt, a.bits) * significand(fmt, b.bits)
    product_high = (product >> ((2 * fmt.wman) - 1)) & 1
    exp_unbiased_base = a.exp + b.exp - (fmt.bias << 1)

    if product_high:
        exp_unbiased = exp_unbiased_base + 1
        significand_value = (product >> fmt.wman) & mask(fmt.wman)
        guard = (product >> (fmt.wman - 1)) & 1
        round_bit = (product >> (fmt.wman - 2)) & 1
        sticky = _sticky_below(product, fmt.wman - 3)
    else:
        exp_unbiased = exp_unbiased_base
        significand_value = (product >> (fmt.wman - 1)) & mask(fmt.wman)
        guard = (product >> (fmt.wman - 2)) & 1
        round_bit = (product >> (fmt.wman - 3)) & 1
        sticky = _sticky_below(product, fmt.wman - 4)

    return pack_reference(
        fmt,
        a.sign ^ b.sign,
        1 if result_zero else 0,
        1 if result_inf else 0,
        exp_unbiased,
        significand_value,
        guard,
        round_bit,
        sticky,
    )


def mul_ilog2_const_reference(fmt: ZkfFormat, a_bits: int, k: int) -> int:
    a = decode(fmt, a_bits)
    if a.is_zero:
        return zero(fmt)
    if a.is_inf:
        return canonical_inf(fmt, a.sign)
    new_exp = a.exp + k
    if new_exp < 0:
        return zero(fmt)
    if new_exp == 0:
        return normal(fmt, a.sign, 1, 0)
    if new_exp > fmt.exp_max_finite:
        return canonical_inf(fmt, a.sign)
    return normal(fmt, a.sign, new_exp, a.frac)


def div_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> tuple[int, int]:
    a = decode(fmt, a_bits)
    b = decode(fmt, b_bits)
    div0 = 1 if b.is_zero else 0

    if a.is_zero or b.is_inf:
        return zero(fmt), div0

    result_sign = a.sign if b.is_zero else (a.sign ^ b.sign)
    if b.is_zero or a.is_inf:
        return canonical_inf(fmt, result_sign), div0

    value = Fraction(significand(fmt, a.bits), significand(fmt, b.bits))
    value *= pow2_fraction(a.exp - b.exp)
    return round_fraction_to_zkf(fmt, result_sign, value), div0


def add_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> int:
    a = decode(fmt, a_bits)
    b = decode(fmt, b_bits)

    if a.is_inf and b.is_inf:
        return canonical_inf(fmt, a.sign) if a.sign == b.sign else zero(fmt)
    if a.is_inf:
        return canonical_inf(fmt, a.sign)
    if b.is_inf:
        return canonical_inf(fmt, b.sign)

    def finite_value(item: Decoded, sign: int) -> Fraction:
        if item.is_zero:
            return Fraction(0, 1)
        value = Fraction(significand(fmt, item.bits), 1)
        value *= pow2_fraction(item.exp - fmt.bias - fmt.wfrac)
        return -value if sign else value

    result = finite_value(a, a.sign) + finite_value(b, b.sign)
    if result == 0:
        return zero(fmt)
    return round_fraction_to_zkf(fmt, 1 if result < 0 else 0, abs(result))


def fma_reference(fmt: ZkfFormat, a_bits: int, b_bits: int, c_bits: int) -> int:
    """Correctly-rounded fused multiply-add: round(a*b + c) with a single rounding.

    The product's special handling matches mul_reference (a or b zero gives +0, including 0*inf; inf times a
    nonzero finite gives signed inf). The infinity combination with c then matches add_reference. The finite case
    computes the exact a*b + c as a Fraction and rounds exactly once, so it is strictly more accurate than the
    chained add_reference(mul_reference(a, b), c), which rounds the product before adding."""
    a = decode(fmt, a_bits)
    b = decode(fmt, b_bits)
    c = decode(fmt, c_bits)

    p_zero = a.is_zero or b.is_zero
    p_inf = (not p_zero) and (a.is_inf or b.is_inf)
    p_sign = a.sign ^ b.sign

    if p_inf and c.is_inf:
        return canonical_inf(fmt, p_sign) if p_sign == c.sign else zero(fmt)
    if p_inf:
        return canonical_inf(fmt, p_sign)
    if c.is_inf:
        return canonical_inf(fmt, c.sign)

    def finite_value(item: Decoded, sign: int) -> Fraction:
        if item.is_zero:
            return Fraction(0, 1)
        value = Fraction(significand(fmt, item.bits), 1)
        value *= pow2_fraction(item.exp - fmt.bias - fmt.wfrac)
        return -value if sign else value

    if p_zero:
        product = Fraction(0, 1)
    else:
        product = Fraction(significand(fmt, a.bits) * significand(fmt, b.bits), 1)
        product *= pow2_fraction(a.exp + b.exp - 2 * fmt.bias - 2 * fmt.wfrac)
        if p_sign:
            product = -product

    result = product + finite_value(c, c.sign)
    if result == 0:
        return zero(fmt)
    return round_fraction_to_zkf(fmt, 1 if result < 0 else 0, abs(result))


def canonicalize_special(fmt: ZkfFormat, bits: int) -> int:
    item = decode(fmt, bits)
    if item.is_zero:
        return zero(fmt)
    if item.is_inf:
        return canonical_inf(fmt, item.sign)
    return item.bits


def ordered_key(fmt: ZkfFormat, bits: int) -> int:
    canonical = canonicalize_special(fmt, bits)
    sign = (canonical >> fmt.sign_shift) & 1
    return (~canonical & mask(fmt.wfull)) if sign else (canonical | (1 << fmt.sign_shift))


def cmp_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> tuple[int, int, int]:
    a_key = ordered_key(fmt, a_bits)
    b_key = ordered_key(fmt, b_bits)
    return int(a_key > b_key), int(a_key == b_key), int(a_key < b_key)


def sort_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> tuple[int, int]:
    _, _, a_lt_b = cmp_reference(fmt, a_bits, b_bits)
    return (a_bits, b_bits) if a_lt_b else (b_bits, a_bits)


def abs_reference(fmt: ZkfFormat, bits: int) -> int:
    return bits & mask(fmt.sign_shift)


def neg_reference(fmt: ZkfFormat, bits: int) -> int:
    return (bits ^ (1 << fmt.sign_shift)) & mask(fmt.wfull)


def is_finite_reference(fmt: ZkfFormat, bits: int) -> int:
    return int(not decode(fmt, bits).is_inf)


def saturate_reference(fmt: ZkfFormat, bits: int) -> int:
    item = decode(fmt, bits)
    if not item.is_inf:
        return item.bits
    return normal(fmt, item.sign, fmt.exp_max_finite, fmt.frac_mask)


def signed_int_min(wint: int) -> int:
    if wint < 2:
        raise ValueError(f"wint must be at least 2, got {wint}")
    return -(1 << (wint - 1))


def signed_int_max(wint: int) -> int:
    if wint < 2:
        raise ValueError(f"wint must be at least 2, got {wint}")
    return (1 << (wint - 1)) - 1


def from_int_reference(fmt: ZkfFormat, wint: int, value: int) -> int:
    if not signed_int_min(wint) <= value <= signed_int_max(wint):
        raise ValueError(f"value={value} out of signed {wint}-bit range")
    if value == 0:
        return zero(fmt)
    sign = 1 if value < 0 else 0
    magnitude = -value if value < 0 else value
    return round_fraction_to_zkf(fmt, sign, Fraction(magnitude, 1))


def _round_fraction_to_int_ties_even(value: Fraction) -> int:
    floor = value.numerator // value.denominator
    frac_part = value - Fraction(floor, 1)
    half = Fraction(1, 2)
    if frac_part < half:
        return floor
    if frac_part > half:
        return floor + 1
    return floor if (floor % 2 == 0) else floor + 1


def to_int_reference(fmt: ZkfFormat, wint: int, bits: int) -> int:
    int_max = signed_int_max(wint)
    int_min = signed_int_min(wint)
    item = decode(fmt, bits)
    if item.is_inf:
        return int_min if item.sign else int_max
    if item.is_zero:
        return 0

    exp_unbiased = item.exp - fmt.bias
    sig_int = significand(fmt, bits)
    magnitude = Fraction(sig_int, 1) * pow2_fraction(exp_unbiased - fmt.wfrac)
    rounded = _round_fraction_to_int_ties_even(-magnitude if item.sign else magnitude)
    if rounded > int_max:
        return int_max
    if rounded < int_min:
        return int_min
    return rounded


def resize_reference(fmt_in: ZkfFormat, fmt_out: ZkfFormat, bits: int) -> int:
    item = decode(fmt_in, bits)
    if item.is_zero:
        return zero(fmt_out)
    if item.is_inf:
        return canonical_inf(fmt_out, item.sign)

    exp_unbiased = item.exp - fmt_in.bias
    sig_int = significand(fmt_in, bits)
    magnitude = Fraction(sig_int, 1) * pow2_fraction(exp_unbiased - fmt_in.wfrac)
    return round_fraction_to_zkf(fmt_out, item.sign, magnitude)


# --------------------------------------------------------------------------------------------------
# Transcendental operators zkf_exp2 / zkf_log2.
#
# *_reference is bit-exact to the RTL datapath: the same fixed-point table+Horner from the generator
# float/zkf_transcendental.py, the same argument reduction, renormalize and pack. So "RTL == reference"
# is an exact-match check like every other operator (exhaustive on small formats, random on large).
# *_true is the correctly-rounded (ties-to-even) mathematical result via mpmath, used by the accuracy
# assertion (target 0.5 ULP; <=1 ULP guaranteed). mpmath is imported lazily so the cocotb path, which
# needs only the bit-exact references, does not hard-depend on it.
# --------------------------------------------------------------------------------------------------

_TRANS_SPECS = None


def _trans_spec(func: str, wman: int) -> dict:
    global _TRANS_SPECS
    if _TRANS_SPECS is None:
        import zkf_trans_tables
        _TRANS_SPECS = zkf_trans_tables.SPECS
    try:
        return _TRANS_SPECS[(func, wman)]
    except KeyError:
        raise KeyError(f"no {func} table for WMAN={wman}; run float/zkf_transcendental.py --emit")


def _horner_eval(coeffs_idx: list[int], w: int, rw: int) -> int:
    """Truncating fixed-point Horner, bit-identical to hdl/_zkf_horner.v and the generator."""
    acc = coeffs_idx[-1]
    for j in range(len(coeffs_idx) - 2, -1, -1):
        acc = coeffs_idx[j] + ((acc * w) >> rw)  # Python >> floors, matching arithmetic >>> on signed
    return acc


def exp2_reference(fmt: ZkfFormat, bits: int) -> int:
    d = decode(fmt, bits)
    if d.is_inf:
        return canonical_inf(fmt, 0) if d.sign == 0 else zero(fmt)   # +inf -> +inf, -inf -> +0
    if d.is_zero:
        return normal(fmt, 0, fmt.bias, 0)                            # 2**0 = 1.0
    e = d.exp - fmt.bias
    # |x| >= 2^(WEXP-1) is always out of range: overflow (x>0) or underflow (x<0).
    if e >= fmt.wexp - 1:
        return canonical_inf(fmt, 0) if d.sign == 0 else zero(fmt)

    spec = _trans_spec("exp2", fmt.wman)
    ff, cf, rw = spec["argbits"], spec["cf"], spec["rw"]
    sig = significand(fmt, bits)
    shift = e - fmt.wfrac + ff
    if shift >= 0:
        mfix = sig << shift
        lost_sticky = 0
    else:
        rs = -shift
        mfix = sig >> rs
        lost_sticky = 1 if (sig & mask(rs)) else 0
    v = -mfix if d.sign else mfix
    i = v >> ff                              # arithmetic floor -> integer part of x
    f = v & mask(ff)                         # fractional part in [0, 2^FF)

    acc = _horner_eval(spec["coeffs"][f >> rw], f & mask(rw), rw)  # 2**f at scale 2^-cf, in [1,2)
    significand_value = (acc >> (cf - fmt.wfrac)) & mask(fmt.wman)
    guard = (acc >> (cf - fmt.wman)) & 1
    round_bit = (acc >> (cf - fmt.wman - 1)) & 1
    sticky = (1 if (acc & mask(cf - fmt.wman - 1)) else 0) | lost_sticky
    return pack_reference(fmt, 0, 0, 0, i, significand_value, guard, round_bit, sticky)


def log2_reference(fmt: ZkfFormat, bits: int) -> tuple[int, int, int]:
    """Returns (y_bits, domain_error, pole)."""
    d = decode(fmt, bits)
    if d.is_inf and d.sign == 0:
        return canonical_inf(fmt, 0), 0, 0          # log2(+inf) = +inf
    if d.is_zero:
        return canonical_inf(fmt, 1), 0, 1          # log2(+0) = -inf, pole
    if d.sign:
        return canonical_inf(fmt, 1), 1, 0          # log2(x<0) = -inf, domain error

    e = d.exp - fmt.bias
    spec = _trans_spec("log2", fmt.wman)
    cf, rw = spec["cf"], spec["rw"]
    acc = _horner_eval(spec["coeffs"][d.frac >> rw], d.frac & mask(rw), rw)  # P(t) at scale 2^-cf, > 0
    f2 = fmt.wfrac + cf
    l_fix = (d.frac * acc) & mask(f2)            # log2(1+t) = t*P(t) at scale 2^-f2, in [0,1)
    r = (e << f2) + l_fix                         # signed fixed point e + log2(m)
    sign_out = 1 if r < 0 else 0
    magnitude = -r if r < 0 else r
    w_norm = fmt.wexp + f2 + 1
    zero_flag, count, aligned = normshift_reference(w_norm, magnitude)
    significand_value = (aligned >> (w_norm - fmt.wman)) & mask(fmt.wman)
    guard = (aligned >> (w_norm - fmt.wman - 1)) & 1
    round_bit = (aligned >> (w_norm - fmt.wman - 2)) & 1
    sticky = 1 if (aligned & mask(w_norm - fmt.wman - 2)) else 0
    exp_unbiased = (w_norm - 1 - count) - f2
    y = pack_reference(fmt, sign_out, zero_flag, 0, exp_unbiased, significand_value, guard, round_bit, sticky)
    return y, 0, 0


def _mpf_to_fraction(x) -> Fraction:
    """Exact dyadic Fraction of an mpmath mpf (value = man * 2^exp)."""
    import mpmath
    sign, man, exp, _bc = mpmath.mpf(x)._mpf_
    value = Fraction(int(man)) * (Fraction(2) ** int(exp))
    return -value if sign else value


def exp2_true(fmt: ZkfFormat, bits: int) -> int:
    d = decode(fmt, bits)
    if d.is_inf:
        return canonical_inf(fmt, 0) if d.sign == 0 else zero(fmt)
    if d.is_zero:
        return normal(fmt, 0, fmt.bias, 0)
    e = d.exp - fmt.bias
    if e >= fmt.wexp - 1:                          # mirror the reference's out-of-range classification
        return canonical_inf(fmt, 0) if d.sign == 0 else zero(fmt)
    import mpmath as mp
    sig = significand(fmt, bits)
    x = mp.mpf(sig) * mp.power(2, e - fmt.wfrac)
    if d.sign:
        x = -x
    return round_fraction_to_zkf(fmt, 0, _mpf_to_fraction(mp.power(2, x)))


def log2_true(fmt: ZkfFormat, bits: int) -> tuple[int, int, int]:
    d = decode(fmt, bits)
    if d.is_inf and d.sign == 0:
        return canonical_inf(fmt, 0), 0, 0
    if d.is_zero:
        return canonical_inf(fmt, 1), 0, 1
    if d.sign:
        return canonical_inf(fmt, 1), 1, 0
    import mpmath as mp
    e = d.exp - fmt.bias
    sig = significand(fmt, bits)
    x = mp.mpf(sig) * mp.power(2, e - fmt.wfrac)
    val = mp.log(x, 2)
    if val == 0:
        return zero(fmt), 0, 0
    sign_out = 1 if val < 0 else 0
    return round_fraction_to_zkf(fmt, sign_out, abs(_mpf_to_fraction(val))), 0, 0


def is_canonical_numpy_operand(fmt: ZkfFormat, bits: int) -> bool:
    item = decode(fmt, bits)
    if item.exp == 0:
        return item.frac == 0
    if item.exp == fmt.exp_inf:
        return item.frac == 0
    return True


def _bits_to_numpy(bits: int, dtype: type[np.float32] | type[np.float64]) -> np.float32 | np.float64:
    if dtype is np.float32:
        return np.array([bits], dtype=np.uint32).view(np.float32)[0]
    return np.array([bits], dtype=np.uint64).view(np.float64)[0]


def _numpy_to_bits(value: np.float32 | np.float64, dtype: type[np.float32] | type[np.float64]) -> int:
    if dtype is np.float32:
        return int(np.array([value], dtype=np.float32).view(np.uint32)[0])
    return int(np.array([value], dtype=np.float64).view(np.uint64)[0])


def _numpy_dtype(fmt: ZkfFormat) -> type[np.float32] | type[np.float64] | None:
    if (fmt.wexp, fmt.wman) == (8, 24):
        return np.float32
    if (fmt.wexp, fmt.wman) == (11, 53):
        return np.float64
    return None


def _canonicalize_numpy_result(fmt: ZkfFormat, bits: int) -> int:
    item = decode(fmt, bits)
    if item.exp == 0:
        if item.frac >= (1 << (fmt.wfrac - 1)):
            return normal(fmt, item.sign, 1, 0)
        return zero(fmt)
    if item.exp == fmt.exp_inf:
        return zero(fmt) if item.frac != 0 else canonical_inf(fmt, item.sign)
    return item.bits


def _ieee_underflowed_to_subnormal(fmt: ZkfFormat, bits: int) -> bool:
    """True if the raw IEEE result is a (nonzero) subnormal.

    ZKF rounds the *exact* result against the 0.5*MIN_NORMAL flush boundary, whereas the FPU first
    rounds the exact value to the nearest subnormal (gradual underflow) and we then canonicalize that
    subnormal. Those are two roundings, and within ~1 ULP of the boundary they can disagree: e.g.
    binary32 0x80800003 / 0x40000004 has an exact magnitude of 0.99999988*(0.5*MIN_NORMAL) -> ZKF
    flushes to +0, but float32 rounds the quotient up to the subnormal 0x80400000 which canonicalizes
    to -MIN_NORMAL. The NumPy result is therefore not a valid oracle for ZKF once it underflows to a
    subnormal, so callers skip the cross-check there. The exact model itself still defines the value,
    and the flush boundary is covered by the exhaustive small-format simulations and the formal proofs."""
    item = decode(fmt, bits)
    return item.exp == 0 and item.frac != 0


def numpy_mul_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> int | None:
    dtype = _numpy_dtype(fmt)
    if dtype is None or not is_canonical_numpy_operand(fmt, a_bits) or not is_canonical_numpy_operand(fmt, b_bits):
        return None
    with np.errstate(all="ignore"):
        result = dtype(_bits_to_numpy(a_bits, dtype)) * dtype(_bits_to_numpy(b_bits, dtype))
    raw = _numpy_to_bits(result, dtype)
    if _ieee_underflowed_to_subnormal(fmt, raw):
        return None
    return _canonicalize_numpy_result(fmt, raw)


def numpy_div_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> tuple[int, int] | None:
    dtype = _numpy_dtype(fmt)
    if dtype is None or not is_canonical_numpy_operand(fmt, a_bits) or not is_canonical_numpy_operand(fmt, b_bits):
        return None

    a = decode(fmt, a_bits)
    b = decode(fmt, b_bits)
    div0 = 1 if b.is_zero else 0

    if a.is_zero or b.is_inf:
        return zero(fmt), div0

    result_sign = a.sign if b.is_zero else (a.sign ^ b.sign)
    if b.is_zero or a.is_inf:
        return canonical_inf(fmt, result_sign), div0

    with np.errstate(all="ignore"):
        result = dtype(_bits_to_numpy(a_bits, dtype)) / dtype(_bits_to_numpy(b_bits, dtype))
    raw = _numpy_to_bits(result, dtype)
    if _ieee_underflowed_to_subnormal(fmt, raw):
        return None
    return _canonicalize_numpy_result(fmt, raw), div0


def numpy_add_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> int | None:
    dtype = _numpy_dtype(fmt)
    if dtype is None or not is_canonical_numpy_operand(fmt, a_bits) or not is_canonical_numpy_operand(fmt, b_bits):
        return None

    a = decode(fmt, a_bits)
    b = decode(fmt, b_bits)
    if a.is_inf and b.is_inf:
        return canonical_inf(fmt, a.sign) if a.sign == b.sign else zero(fmt)
    if a.is_inf:
        return canonical_inf(fmt, a.sign)
    if b.is_inf:
        return canonical_inf(fmt, b.sign)

    lhs = dtype(_bits_to_numpy(a_bits, dtype))
    rhs = dtype(_bits_to_numpy(b_bits, dtype))
    with np.errstate(all="ignore"):
        result = dtype(lhs + rhs)
    raw = _numpy_to_bits(result, dtype)
    if _ieee_underflowed_to_subnormal(fmt, raw):
        return None
    return _canonicalize_numpy_result(fmt, raw)


def numpy_fma_reference(fmt: ZkfFormat, a_bits: int, b_bits: int, c_bits: int) -> int | None:
    """math.fma is a correctly-rounded single-rounding FMA on Python floats (binary64), so it is an exact oracle
    only for the (11, 53) config and only for finite canonical operands (IEEE 0*inf -> NaN differs from ZKF)."""
    if _numpy_dtype(fmt) is not np.float64:
        return None
    if not all(is_canonical_numpy_operand(fmt, bits) for bits in (a_bits, b_bits, c_bits)):
        return None
    a = decode(fmt, a_bits)
    b = decode(fmt, b_bits)
    c = decode(fmt, c_bits)
    if a.is_inf or b.is_inf or c.is_inf:
        return None
    try:
        result = math.fma(
            float(_bits_to_numpy(a_bits, np.float64)),
            float(_bits_to_numpy(b_bits, np.float64)),
            float(_bits_to_numpy(c_bits, np.float64)),
        )
    except (OverflowError, ValueError):
        return None
    if math.isinf(result) or math.isnan(result):
        return None
    raw = _numpy_to_bits(np.float64(result), np.float64)
    if _ieee_underflowed_to_subnormal(fmt, raw):
        return None
    return _canonicalize_numpy_result(fmt, raw)


def lod_reference(width: int, value: int) -> tuple[int, int]:
    """Reference for _zkf_lod: returns (zero, shamt). shamt = (width-1) - leading_one_position, i.e. the
    left-shift that brings the leading 1 to the MSB. shamt is don't-care when zero is asserted."""
    value &= mask(width)
    if value == 0:
        return 1, 0
    return 0, (width - 1) - (value.bit_length() - 1)


def normshift_reference(width: int, value: int) -> tuple[int, int, int]:
    """Reference for _zkf_normshift: returns (zero, count, y). count = (width-1) - leading_one_position, i.e. the
    left-shift that brings the leading 1 to the MSB; y = value << count, the normalized vector. count and y are
    don't-care when zero is asserted."""
    value &= mask(width)
    if value == 0:
        return 1, 0, 0
    count = (width - 1) - (value.bit_length() - 1)
    return 0, count, (value << count) & mask(width)


def rshift_sticky_reference(width: int, value: int, shamt: int) -> int:
    """Reference for _zkf_rshift_sticky: y = value >> shamt, with y[0] OR-collecting every dropped bit
    (and the bit landing at position 0). For shamt >= width the result is {0, |value}."""
    value &= mask(width)
    if shamt >= width:
        shifted, dropped = 0, value
    else:
        shifted, dropped = value >> shamt, value & mask(shamt)
    return (shifted | (1 if dropped else 0)) & mask(width)


def hex_bits(value: int, width: int) -> str:
    return f"0x{value & mask(width):0{(width + 3) // 4}x}"
