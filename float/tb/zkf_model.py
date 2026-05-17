#!/usr/bin/env python3
"""Exact Python model of the Zubax Kulibin floating-point RTL."""

from __future__ import annotations

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

    if exp_unbiased < fmt.min_exp_unbiased:
        return zero(fmt)
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
    exp_underflow = exp_unbiased < fmt.min_exp_unbiased
    exp_one_below_min = exp_unbiased == (fmt.min_exp_unbiased - 1)
    exp_overflow = exp_unbiased > fmt.max_exp_unbiased

    round_increment = bool(guard and (round_bit or sticky or (significand_value & 1)))
    rounded_ext = (significand_value & mask(fmt.wman)) + (1 if round_increment else 0)
    round_carry = (rounded_ext >> fmt.wman) & 1
    rounded_significand = (rounded_ext >> 1) if round_carry else (rounded_ext & mask(fmt.wman))
    exp_round_overflow = (exp_biased == fmt.exp_max_finite) and bool(round_carry)
    infinity = bool(force_inf or exp_overflow or exp_round_overflow)

    underflow_after_round = exp_underflow and not (exp_one_below_min and bool(round_carry))
    result_zero = bool(force_zero or ((not force_inf) and underflow_after_round))
    result_infinity = (not result_zero) and infinity

    if result_zero:
        return zero(fmt)
    if result_infinity:
        return canonical_inf(fmt, sign)

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
        return zero(fmt)
    if item.exp == fmt.exp_inf:
        return zero(fmt) if item.frac != 0 else canonical_inf(fmt, item.sign)
    return item.bits


def numpy_mul_reference(fmt: ZkfFormat, a_bits: int, b_bits: int) -> int | None:
    dtype = _numpy_dtype(fmt)
    if dtype is None or not is_canonical_numpy_operand(fmt, a_bits) or not is_canonical_numpy_operand(fmt, b_bits):
        return None
    with np.errstate(all="ignore"):
        result = dtype(_bits_to_numpy(a_bits, dtype)) * dtype(_bits_to_numpy(b_bits, dtype))
    return _canonicalize_numpy_result(fmt, _numpy_to_bits(result, dtype))


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
    return _canonicalize_numpy_result(fmt, _numpy_to_bits(result, dtype)), div0


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
    return _canonicalize_numpy_result(fmt, _numpy_to_bits(result, dtype))


def hex_bits(value: int, width: int) -> str:
    return f"0x{value & mask(width):0{(width + 3) // 4}x}"
