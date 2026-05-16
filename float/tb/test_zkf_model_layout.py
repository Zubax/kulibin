#!/usr/bin/env python3
"""Verify ZKF binary32/binary64 bit layouts against NumPy.

These tests intentionally use NumPy float32/float64 values backed by the platform's FPU hardware as the oracle. This
assumes the platform is IEEE 754-compliant for binary32 and binary64 representation and basic value preservation.
NaNs and subnormals are excluded because ZKF does not support them, and NaN payload/sign handling is not portable.
"""

from __future__ import annotations

from fractions import Fraction
from pathlib import Path
import random
import sys
from typing import NamedTuple
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from zkf_model import (  # noqa: E402
    ZkfFormat,
    _bits_to_numpy,
    _numpy_to_bits,
    canonical_inf,
    decode,
    mask,
    normal,
    pack_bits,
    pow2_fraction,
    round_fraction_to_zkf,
    zero,
)


class LayoutCase(NamedTuple):
    label: str
    bits: int
    sign: int
    exp: int
    frac: int


BINARY32 = ZkfFormat(8, 24)
BINARY64 = ZkfFormat(11, 53)


def bits_to_numpy(bits: int, dtype: type[np.float32] | type[np.float64]) -> np.float32 | np.float64:
    if dtype is np.float32:
        return np.array([bits & mask(32)], dtype=np.uint32).view(np.float32)[0]
    return np.array([bits & mask(64)], dtype=np.uint64).view(np.float64)[0]


def numpy_to_bits(value: np.float32 | np.float64, dtype: type[np.float32] | type[np.float64]) -> int:
    if dtype is np.float32:
        return int(np.array([value], dtype=np.float32).view(np.uint32)[0])
    return int(np.array([value], dtype=np.float64).view(np.uint64)[0])


def exact_normal_magnitude(fmt: ZkfFormat, exp: int, frac: int) -> Fraction:
    significand = (1 << fmt.wfrac) | frac
    return Fraction(significand, 1) * pow2_fraction(exp - fmt.bias - fmt.wfrac)


def manual_binary32_cases() -> list[LayoutCase]:
    return [
        LayoutCase("+zero", 0x00000000, 0, 0x00, 0x000000),
        LayoutCase("-zero", 0x80000000, 1, 0x00, 0x000000),
        LayoutCase("+min_normal", 0x00800000, 0, 0x01, 0x000000),
        LayoutCase("-min_normal", 0x80800000, 1, 0x01, 0x000000),
        LayoutCase("+half", 0x3F000000, 0, 0x7E, 0x000000),
        LayoutCase("+one", 0x3F800000, 0, 0x7F, 0x000000),
        LayoutCase("-one", 0xBF800000, 1, 0x7F, 0x000000),
        LayoutCase("+one_and_half", 0x3FC00000, 0, 0x7F, 0x400000),
        LayoutCase("+two", 0x40000000, 0, 0x80, 0x000000),
        LayoutCase("+max_finite", 0x7F7FFFFF, 0, 0xFE, 0x7FFFFF),
        LayoutCase("-max_finite", 0xFF7FFFFF, 1, 0xFE, 0x7FFFFF),
        LayoutCase("+inf", 0x7F800000, 0, 0xFF, 0x000000),
        LayoutCase("-inf", 0xFF800000, 1, 0xFF, 0x000000),
    ]


def manual_binary64_cases() -> list[LayoutCase]:
    return [
        LayoutCase("+zero", 0x0000000000000000, 0, 0x000, 0x0000000000000),
        LayoutCase("-zero", 0x8000000000000000, 1, 0x000, 0x0000000000000),
        LayoutCase("+min_normal", 0x0010000000000000, 0, 0x001, 0x0000000000000),
        LayoutCase("-min_normal", 0x8010000000000000, 1, 0x001, 0x0000000000000),
        LayoutCase("+half", 0x3FE0000000000000, 0, 0x3FE, 0x0000000000000),
        LayoutCase("+one", 0x3FF0000000000000, 0, 0x3FF, 0x0000000000000),
        LayoutCase("-one", 0xBFF0000000000000, 1, 0x3FF, 0x0000000000000),
        LayoutCase("+one_and_half", 0x3FF8000000000000, 0, 0x3FF, 0x8000000000000),
        LayoutCase("+two", 0x4000000000000000, 0, 0x400, 0x0000000000000),
        LayoutCase("+max_finite", 0x7FEFFFFFFFFFFFFF, 0, 0x7FE, 0xFFFFFFFFFFFFF),
        LayoutCase("-max_finite", 0xFFEFFFFFFFFFFFFF, 1, 0x7FE, 0xFFFFFFFFFFFFF),
        LayoutCase("+inf", 0x7FF0000000000000, 0, 0x7FF, 0x0000000000000),
        LayoutCase("-inf", 0xFFF0000000000000, 1, 0x7FF, 0x0000000000000),
    ]


class ZkfModelLayoutTest(unittest.TestCase):
    def assert_layout_case(
        self,
        fmt: ZkfFormat,
        dtype: type[np.float32] | type[np.float64],
        case: LayoutCase,
    ) -> None:
        value = bits_to_numpy(case.bits, dtype)
        self.assertFalse(np.isnan(value), case.label)
        self.assertEqual(numpy_to_bits(value, dtype), case.bits, case.label)
        self.assertEqual(_numpy_to_bits(value, dtype), case.bits, case.label)
        self.assertEqual(numpy_to_bits(_bits_to_numpy(case.bits, dtype), dtype), case.bits, case.label)

        packed = pack_bits(fmt, case.sign, case.exp, case.frac)
        self.assertEqual(packed, case.bits, case.label)

        decoded = decode(fmt, case.bits)
        self.assertEqual(decoded.sign, case.sign, case.label)
        self.assertEqual(decoded.exp, case.exp, case.label)
        self.assertEqual(decoded.frac, case.frac, case.label)

        if case.exp == 0:
            self.assertTrue(decoded.is_zero, case.label)
            self.assertFalse(decoded.is_normal, case.label)
            self.assertFalse(decoded.is_inf, case.label)
            self.assertEqual(zero(fmt, case.sign), case.bits, case.label)
        elif case.exp == fmt.exp_inf:
            self.assertTrue(decoded.is_inf, case.label)
            self.assertFalse(decoded.is_zero, case.label)
            self.assertFalse(decoded.is_normal, case.label)
            self.assertEqual(canonical_inf(fmt, case.sign), case.bits, case.label)
        else:
            self.assertTrue(decoded.is_normal, case.label)
            self.assertFalse(decoded.is_zero, case.label)
            self.assertFalse(decoded.is_inf, case.label)
            self.assertEqual(normal(fmt, case.sign, case.exp, case.frac), case.bits, case.label)
            self.assertEqual(
                round_fraction_to_zkf(fmt, case.sign, exact_normal_magnitude(fmt, case.exp, case.frac)),
                case.bits,
                case.label,
            )

    def test_manual_binary32_layout(self) -> None:
        for case in manual_binary32_cases():
            with self.subTest(case=case.label):
                self.assert_layout_case(BINARY32, np.float32, case)

    def test_manual_binary64_layout(self) -> None:
        for case in manual_binary64_cases():
            with self.subTest(case=case.label):
                self.assert_layout_case(BINARY64, np.float64, case)

    def test_manual_numpy_values_have_expected_bits(self) -> None:
        binary32_values = [
            (np.float32(0.0), 0x00000000),
            (np.float32(-0.0), 0x80000000),
            (np.float32(0.5), 0x3F000000),
            (np.float32(1.0), 0x3F800000),
            (np.float32(-1.0), 0xBF800000),
            (np.float32(1.5), 0x3FC00000),
            (np.float32(2.0), 0x40000000),
            (np.float32(np.finfo(np.float32).tiny), 0x00800000),
            (np.float32(np.finfo(np.float32).max), 0x7F7FFFFF),
            (np.float32(np.inf), 0x7F800000),
            (np.float32(-np.inf), 0xFF800000),
        ]
        binary64_values = [
            (np.float64(0.0), 0x0000000000000000),
            (np.float64(-0.0), 0x8000000000000000),
            (np.float64(0.5), 0x3FE0000000000000),
            (np.float64(1.0), 0x3FF0000000000000),
            (np.float64(-1.0), 0xBFF0000000000000),
            (np.float64(1.5), 0x3FF8000000000000),
            (np.float64(2.0), 0x4000000000000000),
            (np.float64(np.finfo(np.float64).tiny), 0x0010000000000000),
            (np.float64(np.finfo(np.float64).max), 0x7FEFFFFFFFFFFFFF),
            (np.float64(np.inf), 0x7FF0000000000000),
            (np.float64(-np.inf), 0xFFF0000000000000),
        ]

        for value, bits in binary32_values:
            with self.subTest(dtype="float32", bits=f"0x{bits:08x}"):
                self.assertEqual(numpy_to_bits(value, np.float32), bits)
        for value, bits in binary64_values:
            with self.subTest(dtype="float64", bits=f"0x{bits:016x}"):
                self.assertEqual(numpy_to_bits(value, np.float64), bits)

    def test_random_binary32_normal_layout(self) -> None:
        self.assert_random_normal_layout(BINARY32, np.float32, count=5000, seed=0x32F17A)

    def test_random_binary64_normal_layout(self) -> None:
        self.assert_random_normal_layout(BINARY64, np.float64, count=5000, seed=0x64F17A)

    def assert_random_normal_layout(
        self,
        fmt: ZkfFormat,
        dtype: type[np.float32] | type[np.float64],
        count: int,
        seed: int,
    ) -> None:
        rng = random.Random(seed)
        edge_exponents = [
            1,
            2,
            fmt.bias - 1,
            fmt.bias,
            fmt.bias + 1,
            fmt.exp_max_finite - 1,
            fmt.exp_max_finite,
        ]
        edge_fractions = [
            0,
            1,
            1 << (fmt.wfrac - 1),
            fmt.frac_mask - 1,
            fmt.frac_mask,
        ]

        for index in range(count):
            if index < len(edge_exponents) * len(edge_fractions) * 2:
                sign = (index // (len(edge_exponents) * len(edge_fractions))) & 1
                exp = edge_exponents[(index // len(edge_fractions)) % len(edge_exponents)]
                frac = edge_fractions[index % len(edge_fractions)]
            else:
                sign = rng.randrange(2)
                exp = rng.randint(1, fmt.exp_max_finite)
                frac = rng.getrandbits(fmt.wfrac)

            bits = normal(fmt, sign, exp, frac)
            value = bits_to_numpy(bits, dtype)
            self.assertTrue(np.isfinite(value), f"bits=0x{bits:0{fmt.wfull // 4}x}")
            self.assertNotEqual(value, dtype(0), f"bits=0x{bits:0{fmt.wfull // 4}x}")
            self.assertEqual(numpy_to_bits(value, dtype), bits)
            self.assertEqual(_numpy_to_bits(value, dtype), bits)
            self.assertEqual(numpy_to_bits(_bits_to_numpy(bits, dtype), dtype), bits)

            decoded = decode(fmt, bits)
            self.assertEqual((decoded.sign, decoded.exp, decoded.frac), (sign, exp, frac))
            self.assertTrue(decoded.is_normal)
            self.assertEqual(
                round_fraction_to_zkf(fmt, sign, exact_normal_magnitude(fmt, exp, frac)),
                bits,
            )


if __name__ == "__main__":
    unittest.main()
