#!/usr/bin/env python3
"""Generate deterministic NumPy float32 reference vectors for zkf_div_random_tb.v."""

from __future__ import annotations

from pathlib import Path
import sys

import numpy as np


WEXP = 8
WMAN = 24
VECTOR_COUNT = 20_000

WFRAC = WMAN - 1
WFULL = WEXP + WMAN
EXP_INF = (1 << WEXP) - 1
EXP_MAX_FINITE = EXP_INF - 1
FRAC_MASK = (1 << WFRAC) - 1
SIGN_SHIFT = WEXP + WFRAC
VECTOR_WIDTH = (3 * WFULL) + 1


def pack_bits(sign: int, exp: int, frac: int) -> int:
    return (sign << SIGN_SHIFT) | (exp << WFRAC) | frac


def normal(sign: int, exp: int, frac: int) -> int:
    assert 1 <= exp <= EXP_MAX_FINITE
    return pack_bits(sign, exp, frac)


def canonical_inf(sign: int) -> int:
    return pack_bits(sign, EXP_INF, 0)


def bits_to_float32(bits: int) -> np.float32:
    return np.array([bits], dtype=np.uint32).view(np.float32)[0]


def float32_to_bits(value: np.float32) -> int:
    return int(np.array([value], dtype=np.float32).view(np.uint32)[0])


def exp_field(bits: int) -> int:
    return (bits >> WFRAC) & EXP_INF


def frac_field(bits: int) -> int:
    return bits & FRAC_MASK


def is_nan_or_subnormal(bits: int) -> bool:
    exp = exp_field(bits)
    frac = frac_field(bits)
    return (exp == 0 and frac != 0) or (exp == EXP_INF and frac != 0)


def is_valid_operand(bits: int) -> bool:
    return not is_nan_or_subnormal(bits)


def is_valid_result(bits: int) -> bool:
    return not is_nan_or_subnormal(bits)


def canonicalize_result_bits(bits: int) -> int:
    sign = (bits >> SIGN_SHIFT) & 1
    exp = exp_field(bits)
    if exp == 0:
        return 0
    if exp == EXP_INF:
        return canonical_inf(sign)
    return bits


def div_reference(a: int, b: int) -> tuple[int, int] | None:
    if not is_valid_operand(a) or not is_valid_operand(b):
        return None

    with np.errstate(all="ignore"):
        q = np.float32(bits_to_float32(a)) / np.float32(bits_to_float32(b))

    q_bits = float32_to_bits(q)
    if not is_valid_result(q_bits):
        return None
    return canonicalize_result_bits(q_bits), 1 if exp_field(b) == 0 else 0


def vector_word(a: int, b: int) -> int:
    reference = div_reference(a, b)
    assert reference is not None
    q, div0 = reference
    return (a << (2 * WFULL + 1)) | (b << (WFULL + 1)) | (q << 1) | div0


def directed_cases() -> list[tuple[int, int]]:
    zero = 0
    one = normal(0, 127, 0)
    minus_one = normal(1, 127, 0)
    half = normal(0, 126, 0)
    one_and_half = normal(0, 127, 1 << (WFRAC - 1))
    one_and_quarter = normal(0, 127, 1 << (WFRAC - 2))
    one_and_three_quarters = normal(0, 127, 3 << (WFRAC - 2))
    two = normal(0, 128, 0)
    min_normal = normal(0, 1, 0)
    neg_min_normal = normal(1, 1, 0)
    max_finite = normal(0, EXP_MAX_FINITE, FRAC_MASK)
    neg_max_finite = normal(1, EXP_MAX_FINITE, FRAC_MASK)
    pos_inf = canonical_inf(0)
    neg_inf = canonical_inf(1)

    return [
        (zero, one),
        (one, zero),
        (minus_one, zero),
        (one, one),
        (minus_one, one),
        (one, minus_one),
        (minus_one, minus_one),
        (one_and_half, two),
        (one_and_quarter, one_and_half),
        (one_and_half, one_and_half),
        (one, pos_inf),
        (minus_one, pos_inf),
        (two, neg_inf),
        (pos_inf, one),
        (neg_inf, one),
        (min_normal, one),
        (neg_min_normal, one),
        (max_finite, one),
        (neg_max_finite, one),
        (max_finite, half),
        (neg_max_finite, half),
        (normal(0, 127, 2), one_and_quarter),
        (normal(0, 127, 1), one_and_half),
        (normal(0, 127, 1), one_and_quarter),
        (normal(0, 127, 1), one_and_three_quarters),
    ]


def random_zero() -> int:
    return 0


def random_inf(rng: np.random.Generator) -> int:
    return canonical_inf(int(rng.integers(0, 2)))


def random_normal_near(rng: np.random.Generator, exponents: list[int], fractions: list[int]) -> int:
    exp = int(np.clip(rng.choice(exponents) + rng.integers(-1, 2), 1, EXP_MAX_FINITE))
    frac_center = int(rng.choice(fractions))
    frac = int(np.clip(frac_center + rng.integers(-16, 17), 0, FRAC_MASK))
    return normal(int(rng.integers(0, 2)), exp, frac)


def random_normal(rng: np.random.Generator) -> int:
    return normal(
        int(rng.integers(0, 2)),
        int(rng.integers(1, EXP_MAX_FINITE + 1)),
        int(rng.integers(0, FRAC_MASK + 1)),
    )


def random_operand(rng: np.random.Generator) -> int:
    mode = int(rng.integers(0, 12))
    if mode == 0:
        return random_zero()
    if mode == 1:
        return random_inf(rng)
    if mode == 2:
        return random_normal_near(rng, [1, 2, 3], [0, 1, FRAC_MASK])
    if mode == 3:
        return random_normal_near(rng, [126, 127, 128], [0, 1, 2, 1 << (WFRAC - 1)])
    if mode == 4:
        return random_normal_near(rng, [252, 253, 254], [0, 1 << (WFRAC - 1), FRAC_MASK])
    return random_normal(rng)


def random_case(rng: np.random.Generator) -> tuple[int, int]:
    mode = int(rng.integers(0, 11))
    if mode == 0:
        return random_zero(), random_operand(rng)
    if mode == 1:
        return random_operand(rng), random_zero()
    if mode == 2:
        return random_normal(rng), random_inf(rng)
    if mode == 3:
        return random_inf(rng), random_normal(rng)
    if mode == 4:
        return random_normal_near(rng, [1, 2], [0, 1]), random_normal_near(rng, [126, 127], [0])
    if mode == 5:
        return random_normal_near(rng, [254], [FRAC_MASK]), random_normal_near(rng, [126, 127], [0])
    if mode == 6:
        return random_normal_near(rng, [126, 127, 128], [0, 1]), random_normal_near(
            rng,
            [126, 127, 128],
            [0, 1, 1 << (WFRAC - 1)],
        )
    return random_operand(rng), random_operand(rng)


def add_case(cases: list[tuple[int, int]], seen: set[tuple[int, int]], case: tuple[int, int]) -> None:
    if case in seen:
        return
    if div_reference(*case) is None:
        return
    seen.add(case)
    cases.append(case)


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd() / "div_random_vectors.memh"
    rng = np.random.default_rng(0x444956)
    cases: list[tuple[int, int]] = []
    seen: set[tuple[int, int]] = set()

    for case in directed_cases():
        add_case(cases, seen, case)

    while len(cases) < VECTOR_COUNT:
        add_case(cases, seen, random_case(rng))

    hex_width = (VECTOR_WIDTH + 3) // 4
    out.write_text("\n".join(f"{vector_word(*case):0{hex_width}x}" for case in cases) + "\n")
    print(f"wrote {len(cases)} vectors to {out}")


if __name__ == "__main__":
    main()
