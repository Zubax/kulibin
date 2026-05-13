#!/usr/bin/env python3
"""Generate deterministic exact-reference vectors for zkf_mul_random_tb.v."""

from __future__ import annotations

from fractions import Fraction
from pathlib import Path
import random


WEXP = 8
WMAN = 24
VECTOR_COUNT = 20_000

WFRAC = WMAN - 1
WFULL = WEXP + WMAN
BIAS = (1 << (WEXP - 1)) - 1
EXP_MAX = (1 << WEXP) - 1
VECTOR_WIDTH = 3 * WFULL


def pow2(k: int) -> Fraction:
    return Fraction(1 << k, 1) if k >= 0 else Fraction(1, 1 << -k)


def pack_bits(sign: int, exp: int, frac: int) -> int:
    return (sign << (WEXP + WFRAC)) | (exp << WFRAC) | frac


def decode(x: int) -> tuple[int, Fraction]:
    sign = (x >> (WEXP + WFRAC)) & 1
    exp = (x >> WFRAC) & ((1 << WEXP) - 1)
    frac = x & ((1 << WFRAC) - 1)

    if exp == 0:
        return sign, Fraction(0, 1)

    significand = (1 << WFRAC) | frac
    return sign, Fraction(significand, 1) * pow2(exp - BIAS - WFRAC)


def floor_log2(x: Fraction) -> int:
    assert x > 0
    exponent = x.numerator.bit_length() - x.denominator.bit_length()
    while x < pow2(exponent):
        exponent -= 1
    while x >= pow2(exponent + 1):
        exponent += 1
    return exponent


def pack_reference(sign: int, exact_abs: Fraction) -> int:
    if exact_abs == 0 or exact_abs < pow2(1 - BIAS):
        return 0

    exponent = floor_log2(exact_abs)
    exp_biased = exponent + BIAS
    scaled = exact_abs * pow2(WFRAC - exponent)
    significand = scaled.numerator // scaled.denominator
    remainder = scaled.numerator % scaled.denominator
    twice_remainder = 2 * remainder

    if (twice_remainder > scaled.denominator) or (
        (twice_remainder == scaled.denominator) and ((significand & 1) != 0)
    ):
        significand += 1

    if significand >= (1 << WMAN):
        significand >>= 1
        exp_biased += 1

    if exp_biased > EXP_MAX:
        return pack_bits(sign, EXP_MAX, (1 << WFRAC) - 1)

    return pack_bits(sign, exp_biased, significand & ((1 << WFRAC) - 1))


def mul_reference(a: int, b: int) -> int:
    sign_a, abs_a = decode(a)
    sign_b, abs_b = decode(b)
    return pack_reference(sign_a ^ sign_b, abs_a * abs_b)


def vector_word(a: int, b: int) -> int:
    y = mul_reference(a, b)
    return (a << (2 * WFULL)) | (b << WFULL) | y


def normal(sign: int, exp: int, frac: int) -> int:
    return pack_bits(sign, exp, frac)


def directed_cases() -> list[tuple[int, int]]:
    one = normal(0, BIAS, 0)
    minus_one = normal(1, BIAS, 0)
    half = normal(0, BIAS - 1, 0)
    one_and_half = normal(0, BIAS, 1 << (WFRAC - 1))
    one_and_quarter = normal(0, BIAS, 1 << (WFRAC - 2))
    one_and_three_quarters = normal(0, BIAS, 3 << (WFRAC - 2))
    two = normal(0, BIAS + 1, 0)
    min_normal = normal(0, 1, 0)
    neg_min_normal = normal(1, 1, 0)
    max_finite = normal(0, EXP_MAX, (1 << WFRAC) - 1)
    neg_max_finite = normal(1, EXP_MAX, (1 << WFRAC) - 1)

    return [
        (0, one),
        (pack_bits(1, 0, 0x5a5a5a), max_finite),
        (minus_one, pack_bits(0, 0, (1 << WFRAC) - 1)),
        (one, one),
        (minus_one, one),
        (minus_one, minus_one),
        (one_and_half, two),
        (one_and_quarter, one_and_half),
        (one_and_half, one_and_half),
        (min_normal, half),
        (min_normal, one),
        (neg_min_normal, one),
        (max_finite, one),
        (max_finite, two),
        (neg_max_finite, two),
        (normal(0, BIAS, 2), one_and_quarter),
        (normal(0, BIAS, 1), one_and_half),
        (normal(0, BIAS, 1), one_and_quarter),
        (normal(0, BIAS, 1), one_and_three_quarters),
    ]


def random_zero(rng: random.Random) -> int:
    return pack_bits(rng.randrange(2), 0, rng.randrange(1 << WFRAC))


def random_normal_near(rng: random.Random, exponents: list[int], fractions: list[int]) -> int:
    exp = max(1, min(EXP_MAX, rng.choice(exponents) + rng.randrange(-1, 2)))
    frac_center = rng.choice(fractions)
    frac = max(0, min((1 << WFRAC) - 1, frac_center + rng.randrange(-16, 17)))
    return normal(rng.randrange(2), exp, frac)


def random_operand(rng: random.Random) -> int:
    mode = rng.randrange(10)
    if mode == 0:
        return random_zero(rng)
    if mode == 1:
        return random_normal_near(rng, [1, 2, 3], [0, 1, (1 << WFRAC) - 1])
    if mode == 2:
        return random_normal_near(rng, [BIAS - 1, BIAS, BIAS + 1], [0, 1, 2, 1 << (WFRAC - 1)])
    if mode == 3:
        return random_normal_near(
            rng,
            [EXP_MAX - 2, EXP_MAX - 1, EXP_MAX],
            [0, (1 << (WFRAC - 1)), (1 << WFRAC) - 1],
        )
    if mode == 4:
        return normal(rng.randrange(2), rng.randrange(1, EXP_MAX + 1), rng.randrange(1 << WFRAC))
    return rng.randrange(1 << WFULL)


def random_case(rng: random.Random) -> tuple[int, int]:
    mode = rng.randrange(8)
    if mode == 0:
        return random_zero(rng), random_operand(rng)
    if mode == 1:
        return random_operand(rng), random_zero(rng)
    if mode == 2:
        return random_normal_near(rng, [1, 2], [0, 1]), random_normal_near(rng, [BIAS - 1, BIAS], [0])
    if mode == 3:
        return random_normal_near(rng, [EXP_MAX], [(1 << WFRAC) - 1]), random_normal_near(
            rng, [BIAS, BIAS + 1], [0, 1]
        )
    return random_operand(rng), random_operand(rng)


def main() -> None:
    out = Path(__file__).with_name("mul_random_vectors.memh")
    rng = random.Random(0x4D554C)
    cases: list[tuple[int, int]] = []
    seen: set[tuple[int, int]] = set()

    for case in directed_cases():
        if case not in seen:
            seen.add(case)
            cases.append(case)

    while len(cases) < VECTOR_COUNT:
        case = random_case(rng)
        if case not in seen:
            seen.add(case)
            cases.append(case)

    hex_width = (VECTOR_WIDTH + 3) // 4
    out.write_text("\n".join(f"{vector_word(*case):0{hex_width}x}" for case in cases) + "\n")
    print(f"wrote {len(cases)} vectors to {out}")


if __name__ == "__main__":
    main()
