#!/usr/bin/env python3
"""Generate deterministic exact-reference vectors for _zkf_pack_random_tb.v."""

from __future__ import annotations

from fractions import Fraction
from pathlib import Path
import random


WEXP = 8
WMAN = 24
WMAG = 48
WSCALE = 10
VECTOR_COUNT = 20_000

WFRAC = WMAN - 1
WFULL = WEXP + WMAN
BIAS = (1 << (WEXP - 1)) - 1
EXP_MAX = (1 << WEXP) - 1
VECTOR_WIDTH = 1 + WMAG + WSCALE + WFULL + 1


def pow2(k: int) -> Fraction:
    return Fraction(1 << k, 1) if k >= 0 else Fraction(1, 1 << -k)


def pack_reference(sign: int, mag: int, scale: int) -> tuple[int, int]:
    exact = Fraction(mag, 1) * pow2(scale)
    if mag == 0 or exact < pow2(1 - BIAS):
        return 0, 0

    log2_mag = mag.bit_length() - 1
    exp_biased = scale + log2_mag + BIAS

    if log2_mag >= WMAN:
        shift = log2_mag - WMAN + 1
        significand = mag >> shift
        remainder = mag & ((1 << shift) - 1)
        half = 1 << (shift - 1)
        if (remainder > half) or ((remainder == half) and ((significand & 1) != 0)):
            significand += 1
    else:
        significand = mag << (WMAN - 1 - log2_mag)

    if significand >= (1 << WMAN):
        significand >>= 1
        exp_biased += 1

    if exp_biased > EXP_MAX:
        return (
            (sign << (WEXP + WFRAC)) | (EXP_MAX << WFRAC) | ((1 << WFRAC) - 1),
            1,
        )

    frac = significand & ((1 << WFRAC) - 1)
    return (sign << (WEXP + WFRAC)) | (exp_biased << WFRAC) | frac, 0


def twos_complement(value: int, width: int) -> int:
    return value & ((1 << width) - 1)


def vector_word(sign: int, mag: int, scale: int) -> int:
    y, saturated = pack_reference(sign, mag, scale)
    return (
        (sign << (WMAG + WSCALE + WFULL + 1))
        | (mag << (WSCALE + WFULL + 1))
        | (twos_complement(scale, WSCALE) << (WFULL + 1))
        | (y << 1)
        | saturated
    )


def directed_cases() -> list[tuple[int, int, int]]:
    return [
        (0, 0, -512),
        (1, 0, 511),
        (0, 1, -127),
        (1, 1 << 9, -136),
        (0, 1, -126),
        (1, 1, -126),
        (0, (1 << 24) + 1, -24),
        (0, (1 << 24) + 3, -24),
        (1, (1 << 24) + 1, -24),
        (0, (1 << 25) - 1, -24),
        (1, (1 << 25) - 1, -24),
        (0, (1 << 24) - 1, 105),
        (1, (1 << 24) - 1, 105),
        (0, (1 << 25) - 2, 104),
        (1, (1 << 25) - 2, 104),
        (0, (1 << 25) - 1, 104),
        (1, (1 << 25) - 1, 104),
        (0, (1 << 47) - 1, 511),
        (1, (1 << 47) - 1, 511),
    ]


def random_case(rng: random.Random) -> tuple[int, int, int]:
    sign = rng.randrange(2)
    mode = rng.randrange(12)

    if mode == 0:
        mag = 0
    elif mode <= 3:
        width = rng.randrange(1, WMAG + 1)
        mag = (1 << (width - 1)) | rng.getrandbits(width - 1)
    elif mode <= 5:
        center = rng.choice([1, (1 << 23), (1 << 24), (1 << 25), (1 << 47)])
        delta = rng.randrange(-16, 17)
        mag = max(0, min((1 << WMAG) - 1, center + delta))
    else:
        mag = rng.randrange(1 << WMAG)

    if mode in (1, 4):
        scale = rng.randrange(-512, -120)
    elif mode in (2, 5):
        scale = rng.randrange(96, 130)
    elif mode == 3:
        scale = rng.choice([-126, -125, -24, -1, 0, 1, 104, 105])
    else:
        scale = rng.randrange(-512, 512)

    return sign, mag, scale


def main() -> None:
    out = Path(__file__).with_name("pack_random_vectors.memh")
    rng = random.Random(0x2C0FFEE)
    cases: list[tuple[int, int, int]] = []
    seen: set[tuple[int, int, int]] = set()

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
