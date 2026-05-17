#!/usr/bin/env python3
"""Shared ZKF operand constructors and low-level random primitives."""

from __future__ import annotations

import numpy as np

from zkf_model import ZkfFormat, canonical_inf, mask, normal, pack_bits, zero


def directed_numbers(fmt: ZkfFormat) -> dict[str, int]:
    if fmt.bias - 1 < 1 or fmt.bias + 1 > fmt.exp_max_finite:
        raise ValueError(f"format too small for generic directed values: {fmt}")
    return {
        "zero": zero(fmt),
        "neg_zero": pack_bits(fmt, 1, 0, min(fmt.frac_mask, 1)),
        "one": normal(fmt, 0, fmt.bias, 0),
        "minus_one": normal(fmt, 1, fmt.bias, 0),
        "half": normal(fmt, 0, fmt.bias - 1, 0),
        "one_and_half": normal(fmt, 0, fmt.bias, 1 << (fmt.wfrac - 1)),
        "one_and_quarter": normal(fmt, 0, fmt.bias, 1 << (fmt.wfrac - 2)),
        "one_and_three_quarters": normal(fmt, 0, fmt.bias, 3 << (fmt.wfrac - 2)),
        "two": normal(fmt, 0, fmt.bias + 1, 0),
        "min_normal": normal(fmt, 0, 1, 0),
        "neg_min_normal": normal(fmt, 1, 1, 0),
        "max_finite": normal(fmt, 0, fmt.exp_max_finite, fmt.frac_mask),
        "neg_max_finite": normal(fmt, 1, fmt.exp_max_finite, fmt.frac_mask),
        "pos_inf": canonical_inf(fmt, 0),
        "neg_inf": canonical_inf(fmt, 1),
        "noncanonical_pos_inf": pack_bits(fmt, 0, fmt.exp_inf, min(fmt.frac_mask, 1)),
        "noncanonical_neg_inf": pack_bits(fmt, 1, fmt.exp_inf, fmt.frac_mask),
    }


def random_normal(fmt: ZkfFormat, rng: np.random.Generator) -> int:
    return normal(
        fmt,
        int(rng.integers(0, 2)),
        int(rng.integers(1, fmt.exp_max_finite + 1)),
        int(rng.integers(0, fmt.frac_mask + 1)),
    )


def random_normal_near(
    fmt: ZkfFormat,
    rng: np.random.Generator,
    exponents: list[int],
    fractions: list[int],
) -> int:
    exp = int(np.clip(int(rng.choice(exponents)) + int(rng.integers(-1, 2)), 1, fmt.exp_max_finite))
    frac = int(np.clip(int(rng.choice(fractions)) + int(rng.integers(-16, 17)), 0, fmt.frac_mask))
    return normal(fmt, int(rng.integers(0, 2)), exp, frac)


def random_zero(fmt: ZkfFormat, rng: np.random.Generator) -> int:
    frac = 0 if int(rng.integers(0, 3)) else int(rng.integers(0, fmt.frac_mask + 1))
    return pack_bits(fmt, int(rng.integers(0, 2)), 0, frac)


def random_inf(fmt: ZkfFormat, rng: np.random.Generator) -> int:
    frac = 0 if int(rng.integers(0, 3)) else int(rng.integers(0, fmt.frac_mask + 1))
    return pack_bits(fmt, int(rng.integers(0, 2)), fmt.exp_inf, frac)


def random_operand(fmt: ZkfFormat, rng: np.random.Generator) -> int:
    mode = int(rng.integers(0, 12))
    if mode == 0:
        return random_zero(fmt, rng)
    if mode == 1:
        return random_inf(fmt, rng)
    if mode == 2:
        return random_normal_near(fmt, rng, [1, 2, 3], [0, 1, fmt.frac_mask])
    if mode == 3:
        return random_normal_near(fmt, rng, [fmt.bias - 1, fmt.bias, fmt.bias + 1], [0, 1, 2])
    if mode == 4:
        return random_normal_near(
            fmt,
            rng,
            [fmt.exp_max_finite - 2, fmt.exp_max_finite - 1, fmt.exp_max_finite],
            [0, 1 << (fmt.wfrac - 1), fmt.frac_mask],
        )
    return random_normal(fmt, rng)


def random_bits(width: int, rng: np.random.Generator) -> int:
    value = 0
    offset = 0
    while offset < width:
        chunk = min(31, width - offset)
        value |= int(rng.integers(0, 1 << chunk)) << offset
        offset += chunk
    return value


def random_pack_mag_scale(fmt: ZkfFormat, rng: np.random.Generator) -> tuple[int, int, int]:
    wmag = 2 * fmt.wman
    sign = int(rng.integers(0, 2))
    mode = int(rng.integers(0, 12))

    if mode == 0:
        mag = 0
    elif mode <= 3:
        width = int(rng.integers(1, wmag + 1))
        mag = (1 << (width - 1)) | int(rng.integers(0, 1 << max(width - 1, 1)))
        mag &= mask(wmag)
    elif mode <= 5:
        centers = [1, 1 << max(fmt.wfrac - 1, 0), 1 << fmt.wfrac, 1 << fmt.wman, (1 << wmag) - 1]
        mag = int(np.clip(int(rng.choice(centers)) + int(rng.integers(-16, 17)), 0, mask(wmag)))
    else:
        mag = int(rng.integers(0, 1 << min(wmag, 62)))
        if wmag > 62:
            mag |= int(rng.integers(0, 1 << (wmag - 62))) << 62
        mag &= mask(wmag)

    scale_min = -(1 << (fmt.wexp + 1))
    scale_max = (1 << (fmt.wexp + 1)) - 1
    if mode in (1, 4):
        scale = int(rng.integers(scale_min, fmt.min_exp_unbiased + 4))
    elif mode in (2, 5):
        scale = int(rng.integers(fmt.max_exp_unbiased - wmag - 4, scale_max + 1))
    elif mode == 3:
        scale = int(rng.choice([fmt.min_exp_unbiased, fmt.min_exp_unbiased - 1, -1, 0, 1, fmt.max_exp_unbiased]))
    else:
        scale = int(rng.integers(scale_min, scale_max + 1))
    return sign, mag, scale


def normal_from_significands(fmt: ZkfFormat, ma: int, mb: int) -> tuple[int, int]:
    a = normal(fmt, 0, fmt.bias, ma - (1 << fmt.wfrac))
    b = normal(fmt, 0, fmt.bias, mb - (1 << fmt.wfrac))
    return a, b
