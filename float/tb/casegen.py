#!/usr/bin/env python3
"""Runtime case generators for the Cocotb ZKF tests."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Iterable

import numpy as np

from zkf_model import (
    ZkfFormat,
    add_reference,
    canonical_inf,
    decode,
    div_reference,
    hex_bits,
    ilog2_floor_reference,
    mask,
    mul_reference,
    normal,
    numpy_add_reference,
    numpy_div_reference,
    numpy_mul_reference,
    pack_bits,
    pack_from_mag_scale_case,
    pack_reference,
    signed_range,
    zero,
)


@dataclass(frozen=True)
class PackCase:
    label: str
    sign: int
    force_zero: int
    force_inf: int
    exp_unbiased: int
    significand: int
    guard: int
    round_bit: int
    sticky: int
    expected: int

    def describe(self, fmt: ZkfFormat) -> str:
        return (
            f"{self.label} sign={self.sign} force_zero={self.force_zero} force_inf={self.force_inf} "
            f"exp={self.exp_unbiased} sig={hex_bits(self.significand, fmt.wman)} "
            f"grs={self.guard}{self.round_bit}{self.sticky}"
        )


@dataclass(frozen=True)
class BinaryCase:
    label: str
    a: int
    b: int
    expected: int
    div0: int = 0

    def describe(self, fmt: ZkfFormat) -> str:
        return f"{self.label} a={hex_bits(self.a, fmt.wfull)} b={hex_bits(self.b, fmt.wfull)}"


@dataclass(frozen=True)
class AddCase:
    label: str
    a: int
    b: int
    expected: int

    def describe(self, fmt: ZkfFormat) -> str:
        return f"{self.label} a={hex_bits(self.a, fmt.wfull)} + b={hex_bits(self.b, fmt.wfull)}"


@dataclass(frozen=True)
class Ilog2Case:
    label: str
    x: int
    expected_zero: int
    expected_y: int


def _add_unique_binary(
    cases: list[BinaryCase],
    seen: set[tuple[int, int]],
    label: str,
    fmt: ZkfFormat,
    a: int,
    b: int,
    op: str,
) -> None:
    key = (a & mask(fmt.wfull), b & mask(fmt.wfull))
    if key in seen:
        return
    seen.add(key)
    if op == "mul":
        expected = mul_reference(fmt, a, b)
        np_ref = numpy_mul_reference(fmt, a, b)
        if np_ref is not None and np_ref != expected:
            raise AssertionError(
                f"NumPy cross-check failed for mul {fmt}: a={hex_bits(a, fmt.wfull)} "
                f"b={hex_bits(b, fmt.wfull)} exact={hex_bits(expected, fmt.wfull)} "
                f"numpy={hex_bits(np_ref, fmt.wfull)}"
            )
        cases.append(BinaryCase(label, a, b, expected))
    elif op == "div":
        expected, div0 = div_reference(fmt, a, b)
        np_ref = numpy_div_reference(fmt, a, b)
        if np_ref is not None and np_ref != (expected, div0):
            raise AssertionError(
                f"NumPy cross-check failed for div {fmt}: a={hex_bits(a, fmt.wfull)} "
                f"b={hex_bits(b, fmt.wfull)} exact=({hex_bits(expected, fmt.wfull)}, {div0}) "
                f"numpy=({hex_bits(np_ref[0], fmt.wfull)}, {np_ref[1]})"
            )
        cases.append(BinaryCase(label, a, b, expected, div0))
    else:
        raise ValueError(op)


def _add_unique_add(
    cases: list[AddCase],
    seen: set[tuple[int, int]],
    label: str,
    fmt: ZkfFormat,
    a: int,
    b: int,
) -> None:
    key = (a & mask(fmt.wfull), b & mask(fmt.wfull))
    if key in seen:
        return
    seen.add(key)
    expected = add_reference(fmt, a, b)
    np_ref = numpy_add_reference(fmt, a, b)
    if np_ref is not None and np_ref != expected:
        raise AssertionError(
            f"NumPy cross-check failed for add {fmt}: a={hex_bits(a, fmt.wfull)} + "
            f"b={hex_bits(b, fmt.wfull)} exact={hex_bits(expected, fmt.wfull)} "
            f"numpy={hex_bits(np_ref, fmt.wfull)}"
        )
    cases.append(AddCase(label, a, b, expected))


def _directed_numbers(fmt: ZkfFormat) -> dict[str, int]:
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


def _generic_mul_directed(fmt: ZkfFormat) -> list[tuple[str, int, int]]:
    v = _directed_numbers(fmt)
    return [
        ("zero_times_one", v["zero"], v["one"]),
        ("zero_payload_beats_inf", v["neg_zero"], v["noncanonical_pos_inf"]),
        ("zero_exp_payload_ignored", v["minus_one"], v["neg_zero"]),
        ("one_times_one", v["one"], v["one"]),
        ("minus_one_times_one", v["minus_one"], v["one"]),
        ("minus_one_times_minus_one", v["minus_one"], v["minus_one"]),
        ("one_and_half_times_two", v["one_and_half"], v["two"]),
        ("one_and_quarter_times_one_and_half", v["one_and_quarter"], v["one_and_half"]),
        ("normalization_carry", v["one_and_half"], v["one_and_half"]),
        ("pos_inf_times_one", v["pos_inf"], v["one"]),
        ("noncanonical_pos_inf_times_one", v["noncanonical_pos_inf"], v["one"]),
        ("noncanonical_neg_inf_times_one", v["noncanonical_neg_inf"], v["one"]),
        ("one_times_pos_inf", v["one"], v["pos_inf"]),
        ("minus_one_times_pos_inf", v["minus_one"], v["noncanonical_pos_inf"]),
        ("two_times_neg_inf", v["two"], v["noncanonical_neg_inf"]),
        ("zero_times_inf", v["zero"], v["pos_inf"]),
        ("zero_payload_times_inf", v["neg_zero"], v["noncanonical_neg_inf"]),
        ("inf_times_inf", v["pos_inf"], v["noncanonical_pos_inf"]),
        ("neg_inf_times_pos_inf", v["neg_inf"], v["noncanonical_pos_inf"]),
        ("neg_inf_times_neg_inf", v["noncanonical_neg_inf"], v["noncanonical_neg_inf"]),
        ("min_normal_underflow", v["min_normal"], v["half"]),
        ("min_normal_times_one", v["min_normal"], v["one"]),
        ("neg_min_normal_times_one", v["neg_min_normal"], v["one"]),
        ("max_finite_times_one", v["max_finite"], v["one"]),
        ("neg_max_finite_times_one", v["neg_max_finite"], v["one"]),
        ("max_finite_overflow", v["max_finite"], v["two"]),
        ("neg_max_finite_overflow", v["neg_max_finite"], v["two"]),
    ]


def _generic_add_directed(fmt: ZkfFormat) -> list[tuple[str, int, int]]:
    v = _directed_numbers(fmt)
    return [
        ("zero_plus_one", v["zero"], v["one"]),
        ("zero_payload_plus_one", v["neg_zero"], v["one"]),
        ("one_plus_zero_payload", v["one"], v["neg_zero"]),
        ("one_plus_one", v["one"], v["one"]),
        ("one_plus_minus_one", v["one"], v["minus_one"]),
        ("minus_one_plus_one", v["minus_one"], v["one"]),
        ("minus_one_plus_minus_one", v["minus_one"], v["minus_one"]),
        ("one_plus_half", v["one"], v["half"]),
        ("half_plus_minus_one", v["half"], v["minus_one"]),
        ("one_and_half_plus_one_and_quarter", v["one_and_half"], v["one_and_quarter"]),
        ("normalization_carry", v["one_and_three_quarters"], v["one_and_three_quarters"]),
        ("min_normal_plus_min_normal", v["min_normal"], v["min_normal"]),
        ("min_normal_plus_neg_min_normal", v["min_normal"], v["neg_min_normal"]),
        ("max_finite_plus_one", v["max_finite"], v["one"]),
        ("max_finite_plus_max_finite", v["max_finite"], v["max_finite"]),
        ("neg_max_finite_plus_neg_max_finite", v["neg_max_finite"], v["neg_max_finite"]),
        ("max_finite_plus_neg_max_finite", v["max_finite"], v["neg_max_finite"]),
        ("pos_inf_plus_one", v["pos_inf"], v["one"]),
        ("one_plus_pos_inf", v["one"], v["pos_inf"]),
        ("one_plus_neg_inf", v["one"], v["noncanonical_neg_inf"]),
        ("pos_inf_plus_pos_inf", v["pos_inf"], v["noncanonical_pos_inf"]),
        ("neg_inf_plus_neg_inf", v["neg_inf"], v["noncanonical_neg_inf"]),
        ("pos_inf_plus_neg_inf", v["pos_inf"], v["neg_inf"]),
    ]


def _generic_div_directed(fmt: ZkfFormat) -> list[tuple[str, int, int]]:
    v = _directed_numbers(fmt)
    return [
        ("zero_div_one", v["zero"], v["one"]),
        ("negative_zero_encoding_div_inf", v["neg_zero"], v["pos_inf"]),
        ("zero_div_zero", v["zero"], v["zero"]),
        ("one_div_zero", v["one"], v["zero"]),
        ("minus_one_div_zero", v["minus_one"], v["zero"]),
        ("one_div_zero_payload", v["one"], v["neg_zero"]),
        ("one_div_one", v["one"], v["one"]),
        ("minus_one_div_one", v["minus_one"], v["one"]),
        ("one_div_minus_one", v["one"], v["minus_one"]),
        ("minus_one_div_minus_one", v["minus_one"], v["minus_one"]),
        ("one_and_half_div_two", v["one_and_half"], v["two"]),
        ("one_and_quarter_div_one_and_half", v["one_and_quarter"], v["one_and_half"]),
        ("one_and_half_div_one_and_half", v["one_and_half"], v["one_and_half"]),
        ("one_div_pos_inf", v["one"], v["pos_inf"]),
        ("minus_one_div_pos_inf", v["minus_one"], v["pos_inf"]),
        ("two_div_neg_inf", v["two"], v["neg_inf"]),
        ("pos_inf_div_one", v["pos_inf"], v["one"]),
        ("neg_inf_div_one", v["neg_inf"], v["one"]),
        ("noncanonical_pos_inf_div_minus_one", v["noncanonical_pos_inf"], v["minus_one"]),
        ("pos_inf_div_pos_inf", v["pos_inf"], v["pos_inf"]),
        ("neg_inf_div_pos_inf", v["neg_inf"], v["pos_inf"]),
        ("noncanonical_inf_div_noncanonical_inf", v["noncanonical_neg_inf"], v["noncanonical_pos_inf"]),
        ("min_normal_div_two_underflow", v["min_normal"], v["two"]),
        ("neg_min_normal_div_two_underflow", v["neg_min_normal"], v["two"]),
        ("min_normal_div_one", v["min_normal"], v["one"]),
        ("neg_min_normal_div_one", v["neg_min_normal"], v["one"]),
        ("max_finite_div_one", v["max_finite"], v["one"]),
        ("neg_max_finite_div_one", v["neg_max_finite"], v["one"]),
        ("max_finite_div_half_overflow", v["max_finite"], v["half"]),
        ("neg_max_finite_div_half_overflow", v["neg_max_finite"], v["half"]),
    ]


def _binary32_mul_manual() -> list[tuple[str, int, int, int]]:
    return [
        ("manual_zero", 0x00000000, 0x3F800000, 0x00000000),
        ("manual_zero_payload_beats_inf", 0x805A5A5A, 0x7FFFFFFF, 0x00000000),
        ("manual_zero_exp_ignored", 0xBF800000, 0x007FFFFF, 0x00000000),
        ("manual_one", 0x3F800000, 0x3F800000, 0x3F800000),
        ("manual_neg_one", 0xBF800000, 0x3F800000, 0xBF800000),
        ("manual_neg_neg", 0xBF800000, 0xBF800000, 0x3F800000),
        ("manual_1p5_times_2", 0x3FC00000, 0x40000000, 0x40400000),
        ("manual_1p25_times_1p5", 0x3FA00000, 0x3FC00000, 0x3FF00000),
        ("manual_product_carry", 0x3FC00000, 0x3FC00000, 0x40100000),
        ("manual_inf", 0x7F800000, 0x3F800000, 0x7F800000),
        ("manual_noncanonical_inf", 0x7FFFFFFF, 0x3F800000, 0x7F800000),
        ("manual_noncanonical_neg_inf", 0xFFABCDEF, 0x3F800000, 0xFF800000),
        ("manual_finite_times_inf", 0x3F800000, 0x7F800000, 0x7F800000),
        ("manual_negative_finite_times_inf", 0xBF800000, 0x7F800001, 0xFF800000),
        ("manual_finite_times_neg_inf", 0x40000000, 0xFF800001, 0xFF800000),
        ("manual_zero_times_inf", 0x00000000, 0x7F800000, 0x00000000),
        ("manual_zero_payload_times_inf", 0x805A5A5A, 0xFFABCDEF, 0x00000000),
        ("manual_inf_times_inf", 0x7F800000, 0x7FFFFFFF, 0x7F800000),
        ("manual_neg_inf_times_inf", 0xFF800000, 0x7F800001, 0xFF800000),
        ("manual_neg_inf_times_neg_inf", 0xFFFFFFFF, 0xFFABCDEF, 0x7F800000),
        ("manual_underflow_flush", 0x00800000, 0x3F000000, 0x00000000),
        ("manual_min_normal", 0x00800000, 0x3F800000, 0x00800000),
        ("manual_negative_min_normal", 0x80800000, 0x3F800000, 0x80800000),
        ("manual_max_finite", 0x7F7FFFFF, 0x3F800000, 0x7F7FFFFF),
        ("manual_negative_max_finite", 0xFF7FFFFF, 0x3F800000, 0xFF7FFFFF),
        ("manual_positive_overflow", 0x7F7FFFFF, 0x40000000, 0x7F800000),
        ("manual_negative_overflow", 0xFF7FFFFF, 0x40000000, 0xFF800000),
        ("manual_tie_retained_even", 0x3F800002, 0x3FA00000, 0x3FA00002),
        ("manual_tie_retained_odd", 0x3F800001, 0x3FC00000, 0x3FC00002),
        ("manual_round_down", 0x3F800001, 0x3FA00000, 0x3FA00001),
        ("manual_round_up", 0x3F800001, 0x3FE00000, 0x3FE00002),
    ]


def _binary32_div_manual() -> list[tuple[str, int, int, int, int]]:
    return [
        ("manual_zero_div_one", 0x00000000, 0x3F800000, 0x00000000, 0),
        ("manual_zero_payload_div_inf", 0x805A5A5A, 0x7F800000, 0x00000000, 0),
        ("manual_zero_div_zero", 0x00000000, 0x00000000, 0x00000000, 1),
        ("manual_one_div_zero", 0x3F800000, 0x00000000, 0x7F800000, 1),
        ("manual_minus_one_div_zero", 0xBF800000, 0x00000000, 0xFF800000, 1),
        ("manual_one_div_zero_payload", 0x3F800000, 0x805A5A5A, 0x7F800000, 1),
        ("manual_one_div_one", 0x3F800000, 0x3F800000, 0x3F800000, 0),
        ("manual_minus_one_div_one", 0xBF800000, 0x3F800000, 0xBF800000, 0),
        ("manual_one_div_minus_one", 0x3F800000, 0xBF800000, 0xBF800000, 0),
        ("manual_minus_one_div_minus_one", 0xBF800000, 0xBF800000, 0x3F800000, 0),
        ("manual_1p5_div_2", 0x3FC00000, 0x40000000, 0x3F400000, 0),
        ("manual_1p25_div_1p5", 0x3FA00000, 0x3FC00000, 0x3F555555, 0),
        ("manual_1p5_div_1p5", 0x3FC00000, 0x3FC00000, 0x3F800000, 0),
        ("manual_one_div_inf", 0x3F800000, 0x7F800000, 0x00000000, 0),
        ("manual_minus_one_div_inf", 0xBF800000, 0x7F800000, 0x00000000, 0),
        ("manual_two_div_neg_inf", 0x40000000, 0xFF800000, 0x00000000, 0),
        ("manual_inf_div_one", 0x7F800000, 0x3F800000, 0x7F800000, 0),
        ("manual_neg_inf_div_one", 0xFF800000, 0x3F800000, 0xFF800000, 0),
        ("manual_noncanonical_inf_div_minus_one", 0x7F812345, 0xBF800000, 0xFF800000, 0),
        ("manual_inf_div_inf", 0x7F800000, 0x7F800000, 0x00000000, 0),
        ("manual_neg_inf_div_inf", 0xFF800000, 0x7F800000, 0x00000000, 0),
        ("manual_noncanonical_inf_div_noncanonical_inf", 0xFFFFFFFF, 0x7F812345, 0x00000000, 0),
        ("manual_underflow_flush", 0x00800000, 0x40000000, 0x00000000, 0),
        ("manual_min_normal", 0x00800000, 0x3F800000, 0x00800000, 0),
        ("manual_negative_min_normal", 0x80800000, 0x3F800000, 0x80800000, 0),
        ("manual_max_finite", 0x7F7FFFFF, 0x3F800000, 0x7F7FFFFF, 0),
        ("manual_negative_max_finite", 0xFF7FFFFF, 0x3F800000, 0xFF7FFFFF, 0),
        ("manual_positive_overflow", 0x7F7FFFFF, 0x3F000000, 0x7F800000, 0),
        ("manual_negative_overflow", 0xFF7FFFFF, 0x3F000000, 0xFF800000, 0),
        ("manual_three_div_two", 0x40400000, 0x40000000, 0x3FC00000, 0),
        ("manual_round_case_0", 0x3F800002, 0x3FA00000, 0x3F4CCCD0, 0),
        ("manual_round_case_1", 0x3F800001, 0x3FC00000, 0x3F2AAAAC, 0),
        ("manual_round_case_2", 0x3F800001, 0x3FA00000, 0x3F4CCCCE, 0),
        ("manual_round_case_3", 0x3F800001, 0x3FE00000, 0x3F124926, 0),
    ]


def _random_normal(fmt: ZkfFormat, rng: np.random.Generator) -> int:
    return normal(
        fmt,
        int(rng.integers(0, 2)),
        int(rng.integers(1, fmt.exp_max_finite + 1)),
        int(rng.integers(0, fmt.frac_mask + 1)),
    )


def _random_normal_near(
    fmt: ZkfFormat,
    rng: np.random.Generator,
    exponents: list[int],
    fractions: list[int],
) -> int:
    exp = int(np.clip(int(rng.choice(exponents)) + int(rng.integers(-1, 2)), 1, fmt.exp_max_finite))
    frac = int(np.clip(int(rng.choice(fractions)) + int(rng.integers(-16, 17)), 0, fmt.frac_mask))
    return normal(fmt, int(rng.integers(0, 2)), exp, frac)


def _random_zero(fmt: ZkfFormat, rng: np.random.Generator) -> int:
    frac = 0 if int(rng.integers(0, 3)) else int(rng.integers(0, fmt.frac_mask + 1))
    return pack_bits(fmt, int(rng.integers(0, 2)), 0, frac)


def _random_inf(fmt: ZkfFormat, rng: np.random.Generator) -> int:
    frac = 0 if int(rng.integers(0, 3)) else int(rng.integers(0, fmt.frac_mask + 1))
    return pack_bits(fmt, int(rng.integers(0, 2)), fmt.exp_inf, frac)


def random_operand(fmt: ZkfFormat, rng: np.random.Generator) -> int:
    mode = int(rng.integers(0, 12))
    if mode == 0:
        return _random_zero(fmt, rng)
    if mode == 1:
        return _random_inf(fmt, rng)
    if mode == 2:
        return _random_normal_near(fmt, rng, [1, 2, 3], [0, 1, fmt.frac_mask])
    if mode == 3:
        return _random_normal_near(fmt, rng, [fmt.bias - 1, fmt.bias, fmt.bias + 1], [0, 1, 2])
    if mode == 4:
        return _random_normal_near(
            fmt,
            rng,
            [fmt.exp_max_finite - 2, fmt.exp_max_finite - 1, fmt.exp_max_finite],
            [0, 1 << (fmt.wfrac - 1), fmt.frac_mask],
        )
    return _random_normal(fmt, rng)


def _random_mul_case(fmt: ZkfFormat, rng: np.random.Generator) -> tuple[int, int]:
    v = _directed_numbers(fmt)
    mode = int(rng.integers(0, 10))
    if mode == 0:
        return _random_zero(fmt, rng), random_operand(fmt, rng)
    if mode == 1:
        return random_operand(fmt, rng), _random_zero(fmt, rng)
    if mode == 2:
        return _random_zero(fmt, rng), _random_inf(fmt, rng)
    if mode == 3:
        return _random_inf(fmt, rng), _random_zero(fmt, rng)
    if mode == 4:
        return _random_normal(fmt, rng), _random_inf(fmt, rng)
    if mode == 5:
        return _random_inf(fmt, rng), _random_normal(fmt, rng)
    if mode == 6:
        return _random_inf(fmt, rng), _random_inf(fmt, rng)
    if mode == 7:
        return _random_normal_near(fmt, rng, [1, 2], [0, 1]), _random_normal_near(fmt, rng, [fmt.bias], [0])
    if mode == 8:
        return _random_normal_near(fmt, rng, [fmt.exp_max_finite], [fmt.frac_mask]), v["two"]
    return random_operand(fmt, rng), random_operand(fmt, rng)


def _random_div_case(fmt: ZkfFormat, rng: np.random.Generator) -> tuple[int, int]:
    v = _directed_numbers(fmt)
    mode = int(rng.integers(0, 13))
    if mode == 0:
        return _random_zero(fmt, rng), random_operand(fmt, rng)
    if mode == 1:
        return random_operand(fmt, rng), _random_zero(fmt, rng)
    if mode == 2:
        return _random_normal(fmt, rng), _random_inf(fmt, rng)
    if mode == 3:
        return _random_inf(fmt, rng), _random_normal(fmt, rng)
    if mode == 4:
        return _random_normal_near(fmt, rng, [1, 2], [0, 1]), _random_normal_near(fmt, rng, [fmt.bias], [0])
    if mode == 5:
        return _random_normal_near(fmt, rng, [fmt.exp_max_finite], [fmt.frac_mask]), v["half"]
    if mode == 6:
        return _random_normal_near(fmt, rng, [fmt.bias], [0, 1]), _random_normal_near(
            fmt,
            rng,
            [fmt.bias],
            [0, 1, 1 << (fmt.wfrac - 1)],
        )
    if mode == 7:
        return normal(fmt, int(rng.integers(0, 2)), 1, int(rng.integers(0, min(4, fmt.frac_mask + 1)))), v["two"]
    if mode == 8:
        return normal(fmt, int(rng.integers(0, 2)), fmt.exp_max_finite, fmt.frac_mask), v["half"]
    if mode == 9:
        return _random_normal(fmt, rng), v["one"]
    return random_operand(fmt, rng), random_operand(fmt, rng)


def _random_add_case(fmt: ZkfFormat, rng: np.random.Generator) -> tuple[int, int]:
    v = _directed_numbers(fmt)
    mode = int(rng.integers(0, 14))
    if mode == 0:
        return _random_zero(fmt, rng), random_operand(fmt, rng)
    if mode == 1:
        return random_operand(fmt, rng), _random_zero(fmt, rng)
    if mode == 2:
        return _random_inf(fmt, rng), random_operand(fmt, rng)
    if mode == 3:
        return random_operand(fmt, rng), _random_inf(fmt, rng)
    if mode == 4:
        return _random_inf(fmt, rng), _random_inf(fmt, rng)
    if mode == 5:
        exp = int(rng.integers(1, fmt.exp_max_finite + 1))
        frac = int(rng.integers(0, fmt.frac_mask))
        sign = int(rng.integers(0, 2))
        return normal(fmt, sign, exp, frac + 1), normal(fmt, sign ^ 1, exp, frac)
    if mode == 6:
        exp = int(rng.integers(1, fmt.exp_max_finite + 1))
        frac = int(rng.integers(0, fmt.frac_mask))
        sign = int(rng.integers(0, 2))
        return normal(fmt, sign, exp, frac + 1), normal(fmt, sign ^ 1, exp, frac)
    if mode == 7:
        return _random_normal_near(fmt, rng, [1, 2], [0, 1]), _random_normal_near(fmt, rng, [1, 2], [0, 1])
    if mode == 8:
        return _random_normal_near(
            fmt,
            rng,
            [fmt.exp_max_finite],
            [fmt.frac_mask],
        ), _random_normal_near(fmt, rng, [fmt.exp_max_finite], [fmt.frac_mask])
    if mode == 9:
        return v["max_finite"], v["max_finite"]
    if mode == 10:
        return v["neg_max_finite"], v["neg_max_finite"]
    return random_operand(fmt, rng), random_operand(fmt, rng)


@dataclass(frozen=True)
class DivObservation:
    high: bool
    significand_lsb: int
    guard: int
    round_bit: int
    produced_tail: bool
    final_rem_sticky: bool

    @property
    def sticky(self) -> bool:
        return self.produced_tail or self.final_rem_sticky

    @property
    def round_increment(self) -> bool:
        return bool(self.guard and (self.round_bit or self.sticky or self.significand_lsb))


def _qfrac(fmt: ZkfFormat) -> int:
    qfrac_base = fmt.wman + 2
    return qfrac_base + (qfrac_base % 2)


def _div_observation(fmt: ZkfFormat, a: int, b: int) -> DivObservation | None:
    da = decode(fmt, a)
    db = decode(fmt, b)
    if not da.is_normal or not db.is_normal:
        return None

    qf = _qfrac(fmt)
    sig_a = (1 << fmt.wfrac) | da.frac
    sig_b = (1 << fmt.wfrac) | db.frac
    raw = (sig_a << qf) // sig_b
    rem = (sig_a << qf) % sig_b
    high = ((raw >> qf) & 1) != 0

    if high:
        sig_shift = qf - fmt.wman + 1
        guard_shift = qf - fmt.wman
        round_shift = qf - fmt.wman - 1
        tail_width = qf - fmt.wman - 1
    else:
        sig_shift = qf - fmt.wman
        guard_shift = qf - fmt.wman - 1
        round_shift = qf - fmt.wman - 2
        tail_width = qf - fmt.wman - 2

    sig = (raw >> sig_shift) & mask(fmt.wman)
    tail_mask = mask(tail_width) if tail_width > 0 else 0
    return DivObservation(
        high=high,
        significand_lsb=sig & 1,
        guard=(raw >> guard_shift) & 1,
        round_bit=(raw >> round_shift) & 1,
        produced_tail=(raw & tail_mask) != 0,
        final_rem_sticky=rem != 0,
    )


def _normal_from_significands(fmt: ZkfFormat, ma: int, mb: int) -> tuple[int, int]:
    a = normal(fmt, 0, fmt.bias, ma - (1 << fmt.wfrac))
    b = normal(fmt, 0, fmt.bias, mb - (1 << fmt.wfrac))
    return a, b


def _find_div_rounding_case(
    fmt: ZkfFormat,
    rng: np.random.Generator,
    predicate: Callable[[DivObservation], bool],
    max_random: int = 200_000,
) -> tuple[int, int] | None:
    lo = 1 << fmt.wfrac
    hi = 1 << fmt.wman

    if fmt.wman <= 11:
        for ma in range(lo, hi):
            for mb in range(lo, hi):
                a, b = _normal_from_significands(fmt, ma, mb)
                obs = _div_observation(fmt, a, b)
                if obs is not None and predicate(obs):
                    return a, b

    for _ in range(max_random):
        a, b = _normal_from_significands(fmt, int(rng.integers(lo, hi)), int(rng.integers(lo, hi)))
        obs = _div_observation(fmt, a, b)
        if obs is not None and predicate(obs):
            return a, b

    return None


def _div_rounding_directed(fmt: ZkfFormat, rng: np.random.Generator) -> list[tuple[str, int, int]]:
    predicates: list[tuple[str, Callable[[DivObservation], bool]]] = [
        ("high_quotient_normalization", lambda obs: obs.high),
        ("low_quotient_normalization", lambda obs: not obs.high),
        ("guard_round_increment", lambda obs: bool(obs.guard and obs.round_bit and obs.round_increment)),
        (
            "sticky_from_produced_tail",
            lambda obs: bool(obs.guard and not obs.round_bit and obs.produced_tail and obs.round_increment),
        ),
        (
            "sticky_from_final_remainder",
            lambda obs: bool(obs.guard and not obs.round_bit and not obs.produced_tail and obs.final_rem_sticky),
        ),
    ]
    cases: list[tuple[str, int, int]] = []
    for label, predicate in predicates:
        case = _find_div_rounding_case(fmt, rng, predicate)
        if case is not None:
            cases.append((label, *case))
    return cases


def mul_cases(fmt: ZkfFormat, kind: str, seed: int, count: int) -> list[BinaryCase]:
    cases: list[BinaryCase] = []
    seen: set[tuple[int, int]] = set()

    if kind == "exhaustive":
        for a in range(1 << fmt.wfull):
            for b in range(1 << fmt.wfull):
                _add_unique_binary(cases, seen, "exhaustive", fmt, a, b, "mul")
        return cases

    if fmt.wexp >= 3:
        for label, a, b in _generic_mul_directed(fmt):
            _add_unique_binary(cases, seen, label, fmt, a, b, "mul")

    if (fmt.wexp, fmt.wman) == (8, 24):
        for label, a, b, expected in _binary32_mul_manual():
            actual = mul_reference(fmt, a, b)
            if actual != expected:
                raise AssertionError(f"{label}: expected {expected:08x}, model returned {actual:08x}")
            _add_unique_binary(cases, seen, label, fmt, a, b, "mul")

    if (fmt.wexp, fmt.wman) == (6, 18):
        _add_unique_binary(cases, seen, "default_parameter_smoke", fmt, 0x3E0000, 0x3E0000, "mul")

    rng = np.random.default_rng(seed)
    while len(cases) < count:
        a, b = _random_mul_case(fmt, rng)
        _add_unique_binary(cases, seen, "random", fmt, a, b, "mul")
    return cases


def div_cases(fmt: ZkfFormat, kind: str, seed: int, count: int) -> list[BinaryCase]:
    cases: list[BinaryCase] = []
    seen: set[tuple[int, int]] = set()

    if kind == "exhaustive":
        for a in range(1 << fmt.wfull):
            for b in range(1 << fmt.wfull):
                _add_unique_binary(cases, seen, "exhaustive", fmt, a, b, "div")
        return cases

    rng = np.random.default_rng(seed)
    if fmt.wexp >= 3:
        for label, a, b in _generic_div_directed(fmt):
            _add_unique_binary(cases, seen, label, fmt, a, b, "div")
        for label, a, b in _div_rounding_directed(fmt, rng):
            _add_unique_binary(cases, seen, label, fmt, a, b, "div")

    if (fmt.wexp, fmt.wman) == (8, 24):
        for label, a, b, expected, expected_div0 in _binary32_div_manual():
            actual, actual_div0 = div_reference(fmt, a, b)
            if (actual, actual_div0) != (expected, expected_div0):
                raise AssertionError(
                    f"{label}: expected ({expected:08x}, {expected_div0}), "
                    f"model returned ({actual:08x}, {actual_div0})"
                )
            _add_unique_binary(cases, seen, label, fmt, a, b, "div")

    if (fmt.wexp, fmt.wman) == (6, 18):
        _add_unique_binary(cases, seen, "default_parameter_smoke", fmt, 0x3E0000, 0x3E0000, "div")

    while len(cases) < count:
        a, b = _random_div_case(fmt, rng)
        _add_unique_binary(cases, seen, "random", fmt, a, b, "div")
    return cases


def add_cases(fmt: ZkfFormat, kind: str, seed: int, count: int) -> list[AddCase]:
    cases: list[AddCase] = []
    seen: set[tuple[int, int]] = set()

    if kind == "exhaustive":
        for a in range(1 << fmt.wfull):
            for b in range(1 << fmt.wfull):
                _add_unique_add(cases, seen, "exhaustive", fmt, a, b)
        return cases

    rng = np.random.default_rng(seed)
    if fmt.wexp >= 3:
        for label, a, b in _generic_add_directed(fmt):
            _add_unique_add(cases, seen, label, fmt, a, b)

    if (fmt.wexp, fmt.wman) == (6, 18):
        _add_unique_add(cases, seen, "default_parameter_smoke", fmt, 0x3E0000, 0x3E0000)

    while len(cases) < count:
        a, b = _random_add_case(fmt, rng)
        _add_unique_add(cases, seen, "random", fmt, a, b)
    return cases


def _pack_case(
    fmt: ZkfFormat,
    label: str,
    sign: int,
    force_zero: int,
    force_inf: int,
    exp_unbiased: int,
    significand_value: int,
    guard: int,
    round_bit: int,
    sticky: int,
) -> PackCase:
    return PackCase(
        label=label,
        sign=sign,
        force_zero=force_zero,
        force_inf=force_inf,
        exp_unbiased=exp_unbiased,
        significand=significand_value,
        guard=guard,
        round_bit=round_bit,
        sticky=sticky,
        expected=pack_reference(
            fmt,
            sign,
            force_zero,
            force_inf,
            exp_unbiased,
            significand_value,
            guard,
            round_bit,
            sticky,
        ),
    )


def _pack_directed(fmt: ZkfFormat) -> list[PackCase]:
    min_exp = fmt.min_exp_unbiased
    max_exp = fmt.max_exp_unbiased
    one = 1 << fmt.wfrac
    max_sig = (1 << fmt.wman) - 1
    return [
        _pack_case(fmt, "force_zero_wins_over_force_inf", 1, 1, 1, max_exp + 2, max_sig, 1, 1, 1),
        _pack_case(fmt, "force_inf_overrides_underflow", 1, 0, 1, min_exp - 3, one, 0, 0, 0),
        _pack_case(fmt, "underflow_flush", 0, 0, 0, min_exp - 2, max_sig, 0, 0, 0),
        _pack_case(fmt, "one_below_min_no_promotion", 0, 0, 0, min_exp - 1, max_sig - 1, 1, 0, 0),
        _pack_case(fmt, "one_below_min_round_carry_to_min", 0, 0, 0, min_exp - 1, max_sig, 1, 0, 0),
        _pack_case(fmt, "negative_min_normal", 1, 0, 0, min_exp, one, 0, 0, 0),
        _pack_case(fmt, "tie_retained_even", 0, 0, 0, 0, one, 1, 0, 0),
        _pack_case(fmt, "tie_rounds_odd_up", 0, 0, 0, 0, one + 1, 1, 0, 0),
        _pack_case(fmt, "round_down", 0, 0, 0, 0, one + 1, 0, 1, 1),
        _pack_case(fmt, "round_up", 0, 0, 0, 0, one + 1, 1, 0, 1),
        _pack_case(fmt, "max_finite", 0, 0, 0, max_exp, max_sig, 0, 0, 0),
        _pack_case(fmt, "round_to_infinity", 0, 0, 0, max_exp, max_sig, 1, 0, 0),
        _pack_case(fmt, "explicit_overflow", 1, 0, 0, max_exp + 1, one, 0, 0, 0),
    ]


def _pack_manual_w5_m8() -> list[PackCase]:
    fmt = ZkfFormat(5, 8)
    manual = [
        ("manual_zero_is_canonical", 1, 0, 31, 0x0000),
        ("manual_below_min_flush", 0, 1, -15, 0x0000),
        ("manual_one_below_min_no_carry", 0, 255, -22, 0x0000),
        ("manual_one_below_min_carry", 0, 511, -23, 0x0080),
        ("manual_negative_one_below_min_carry", 1, 511, -23, 0x1080),
        ("manual_min_normal", 0, 1, -14, 0x0080),
        ("manual_negative_min_normal", 1, 1, -14, 0x1080),
        ("manual_one", 0, 1, 0, 0x0780),
        ("manual_minus_one", 1, 1, 0, 0x1780),
        ("manual_one_and_half", 0, 3, -1, 0x07C0),
        ("manual_two", 0, 1, 1, 0x0800),
        ("manual_minus_two", 1, 1, 1, 0x1800),
        ("manual_max_sig_exp_zero", 0, 255, -7, 0x07FF),
        ("manual_round_down", 0, 513, -9, 0x0780),
        ("manual_tie_to_even_lower", 0, 514, -9, 0x0780),
        ("manual_round_up", 0, 515, -9, 0x0781),
        ("manual_tie_to_even_upper", 0, 518, -9, 0x0782),
        ("manual_below_carry_threshold", 0, 1021, -9, 0x07FF),
        ("manual_tie_carry", 0, 511, -8, 0x0800),
        ("manual_negative_tie_carry", 1, 511, -8, 0x1800),
        ("manual_high_input_bit_exact", 0, 0x8000, 0, 0x0F00),
        ("manual_round_carry_to_infinity", 0, 0xFFFF, 0, 0x0F80),
        ("manual_max_finite", 0, 255, 8, 0x0F7F),
        ("manual_above_max_rounds_to_max", 0, 1021, 6, 0x0F7F),
        ("manual_round_to_infinity_tie", 0, 511, 7, 0x0F80),
        ("manual_negative_round_to_infinity_tie", 1, 511, 7, 0x1F80),
        ("manual_exponent_overflow", 0, 1, 16, 0x0F80),
    ]
    cases = []
    for label, sign, mag, scale, expected in manual:
        args = pack_from_mag_scale_case(fmt, sign, mag, scale)
        case = _pack_case(fmt, label, *args)
        if case.expected != expected:
            raise AssertionError(f"{label}: expected {expected:04x}, model returned {case.expected:04x}")
        cases.append(case)
    return cases


def _random_pack_mag_scale(fmt: ZkfFormat, rng: np.random.Generator) -> tuple[int, int, int]:
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


def pack_cases(fmt: ZkfFormat, kind: str, seed: int, count: int, wunbiased: int) -> list[PackCase]:
    if kind == "exhaustive":
        cases: list[PackCase] = []
        for sign in (0, 1):
            for force_zero in (0, 1):
                for force_inf in (0, 1):
                    for exp_unbiased in signed_range(wunbiased):
                        for significand_value in range(1 << fmt.wman):
                            for grs in range(8):
                                cases.append(
                                    _pack_case(
                                        fmt,
                                        "exhaustive",
                                        sign,
                                        force_zero,
                                        force_inf,
                                        exp_unbiased,
                                        significand_value,
                                        (grs >> 2) & 1,
                                        (grs >> 1) & 1,
                                        grs & 1,
                                    )
                                )
        return cases

    cases = _pack_directed(fmt)
    if (fmt.wexp, fmt.wman) == (5, 8):
        cases.extend(_pack_manual_w5_m8())

    rng = np.random.default_rng(seed)
    seen = {
        (
            c.sign,
            c.force_zero,
            c.force_inf,
            c.exp_unbiased,
            c.significand,
            c.guard,
            c.round_bit,
            c.sticky,
        )
        for c in cases
    }
    while len(cases) < count:
        args = pack_from_mag_scale_case(fmt, *_random_pack_mag_scale(fmt, rng))
        key = args
        if key in seen:
            continue
        seen.add(key)
        cases.append(_pack_case(fmt, "random_mag_scale", *args))
    return cases


def ilog2_cases(width: int, seed: int, count: int) -> list[Ilog2Case]:
    cases: list[Ilog2Case] = []
    seen: set[int] = set()

    def add(label: str, value: int) -> None:
        value_masked = value & mask(width)
        if value_masked in seen:
            return
        seen.add(value_masked)
        expected_zero, expected_y = ilog2_floor_reference(width, value_masked)
        cases.append(Ilog2Case(label, value_masked, expected_zero, expected_y))

    if width <= 12:
        for value in range(1 << width):
            add("exhaustive", value)
        return cases

    add("zero", 0)
    for bit in range(width):
        add("power_of_two", 1 << bit)
        add("below_power_of_two", (1 << bit) - 1)
        add("above_power_of_two", (1 << bit) | 1)
    add("all_ones", mask(width))

    rng = np.random.default_rng(seed)
    while len(cases) < count:
        if width <= 62:
            value = int(rng.integers(0, 1 << width))
        else:
            lo = int(rng.integers(0, 1 << 62))
            hi = int(rng.integers(0, 1 << (width - 62)))
            value = (hi << 62) | lo
        add("random", value)
    return cases
