#!/usr/bin/env python3

from dataclasses import dataclass
from fractions import Fraction
import math


@dataclass(frozen=True)
class ZkfParams:
    """
    Exact key parameters of the Zubax Kulibin float format.
    """

    wexp: int
    """Exponent bit width."""
    wman: int
    """Significand bit width; represented with one fewer bit."""

    def __post_init__(self) -> None:
        if self.wexp < 2 or self.wman < 2:
            raise ValueError

    @property
    def wfrac(self) -> int:
        """Stored fraction width."""
        return self.wman - 1

    @property
    def wfull(self) -> int:
        """Total packed width: 1 sign + wexp + wfrac."""
        return 1 + self.wexp + self.wfrac

    @property
    def bias(self) -> int:
        return (1 << (self.wexp - 1)) - 1

    @property
    def exp_infinity(self) -> int:
        """Exponent field value for infinity."""
        return (1 << self.wexp) - 1

    @property
    def exp_max_finite(self) -> int:
        """Largest finite exponent field value."""
        return self.exp_infinity - 1

    @property
    def frac_max(self) -> int:
        return (1 << self.wfrac) - 1

    @property
    def lowest(self) -> Fraction:
        """Smallest representable positive magnitude (no subnormals)."""
        return self._pow2(1 - self.bias)

    @property
    def lowest_normal(self) -> Fraction:
        """Smallest representable positive magnitude (no subnormals)."""
        return self.lowest

    @property
    def max(self) -> Fraction:
        """Largest finite magnitude."""
        max_exp = self.exp_max_finite - self.bias
        return (Fraction(2) - self._pow2(-self.wfrac)) * self._pow2(max_exp)

    @property
    def epsilon(self) -> Fraction:
        """Gap between 1.0 and the next representable value above it."""
        return self._pow2(-self.wfrac)

    @staticmethod
    def _pow2(k: int) -> Fraction:
        return Fraction(1 << k, 1) if k >= 0 else Fraction(1, 1 << -k)

    def encode(self, value: float) -> int:
        sign = 1 if math.copysign(1.0, value) < 0 else 0
        if math.isnan(value):
            raise ValueError("NaN is not representable in ZKF")
        if math.isinf(value):
            return _canonical_inf(self, sign)
        if value == 0.0:
            return 0
        return _round_fraction_to_zkf(self, sign, Fraction.from_float(abs(value)))


def _mask(width: int) -> int:
    return (1 << width) - 1


def _bits_to_signed(bits: int, width: int) -> int:
    bits &= _mask(width)
    sign_bit = 1 << (width - 1)
    return bits - (1 << width) if bits & sign_bit else bits


def _pack_bits(p: ZkfParams, sign: int, exp: int, frac: int) -> int:
    return ((sign & 1) << (p.wexp + p.wfrac)) | ((exp & _mask(p.wexp)) << p.wfrac) | (frac & p.frac_max)


def _canonical_inf(p: ZkfParams, sign: int) -> int:
    return _pack_bits(p, sign, p.exp_infinity, 0)


def _normal(p: ZkfParams, sign: int, exp: int, frac: int) -> int:
    return _pack_bits(p, sign, exp, frac)


def _floor_log2_fraction(value: Fraction) -> int:
    if value <= 0:
        raise ValueError("log2 is defined for positive values only")
    exp = value.numerator.bit_length() - value.denominator.bit_length()
    while ZkfParams._pow2(exp + 1) <= value:
        exp += 1
    while ZkfParams._pow2(exp) > value:
        exp -= 1
    return exp


def _round_fraction_to_zkf(p: ZkfParams, sign: int, value: Fraction) -> int:
    if value <= 0:
        return 0
    min_exp_unbiased = 1 - p.bias
    max_exp_unbiased = p.exp_max_finite - p.bias
    exp_unbiased = _floor_log2_fraction(value)
    if exp_unbiased < min_exp_unbiased:
        return _normal(p, sign, 1, 0) if value >= ZkfParams._pow2(min_exp_unbiased - 1) else 0
    scaled = value / ZkfParams._pow2(exp_unbiased) * (1 << p.wfrac)
    quotient = scaled.numerator // scaled.denominator
    remainder = scaled.numerator % scaled.denominator
    twice_remainder = 2 * remainder
    increment = twice_remainder > scaled.denominator
    increment = increment or (twice_remainder == scaled.denominator and (quotient & 1) != 0)
    if increment:
        quotient += 1
    if quotient >= (1 << p.wman):
        quotient >>= 1
        exp_unbiased += 1
    if exp_unbiased > max_exp_unbiased:
        return _canonical_inf(p, sign)
    return _normal(p, sign, exp_unbiased + p.bias, quotient & p.frac_max)


if __name__ == "__main__":
    import sys
    if len(sys.argv) not in (3, 4):
        raise SystemExit(f"usage: {sys.argv[0]} WEXP WMAN [VALUE]")

    wexp, wman = map(int, (sys.argv[1], sys.argv[2]))
    p = ZkfParams(wexp, wman)
    print(f"WEXP={p.wexp} WMAN={p.wman} WFRAC={p.wfrac} WFULL={p.wfull} BIAS={p.bias}")
    print(f"lowest     = {p.lowest} ≈ {float(p.lowest):.3e}")
    print(f"max        = {p.max} ≈ {float(p.max):.3e}")
    print(f"ε          = {p.epsilon} ≈ {float(p.epsilon):.3e}")

    bit_diagram = "s" + "e" * p.wexp + "f" * p.wfrac
    print(bit_diagram)
    print(("0123456789" * ((p.wfull + 10)//10))[:p.wfull][::-1])
    print("".join((f"{x}" * 10) for x in range(10))[:p.wfull][::-1])

    if len(sys.argv) > 3:
        value = float(sys.argv[3])
        print(f"Value {value} represented in this format:")
        bits = p.encode(value)
        print(f"signed decimal: {_bits_to_signed(bits, p.wfull):+d}")
        print(f"twos-complement: {bits:0{p.wfull}b}")
        print(f"                 {bit_diagram}")
