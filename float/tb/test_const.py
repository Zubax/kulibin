#!/usr/bin/env python3
"""Cocotb test for zkf_const, driven through the zkf_const_wrap harness."""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
import math

import cocotb
from cocotb.triggers import Timer

from zkf_model import ZkfFormat, canonical_inf, hex_bits, round_fraction_to_zkf, zero
from zkf_params import check_width, float_context
from zkf_stream import is_resolvable


@dataclass(frozen=True)
class ConstCase:
    port: str
    value: float


CASES: tuple[ConstCase, ...] = (
    ConstCase("y_zero",     0.0),
    ConstCase("y_neg_zero", -0.0),
    ConstCase("y_one",      1.0),
    ConstCase("y_neg_one", -1.0),
    ConstCase("y_two",      2.0),
    ConstCase("y_half",     0.5),
    ConstCase("y_pi",       math.pi),
    ConstCase("y_neg_pi",  -math.pi),
    ConstCase("y_e",        math.e),
    ConstCase("y_ln2",      math.log(2)),
    ConstCase("y_sqrt2",    math.sqrt(2)),
    ConstCase("y_third",    1.0 / 3.0),
    ConstCase("y_pos_inf",  math.inf),
    ConstCase("y_neg_inf", -math.inf),
)


def expected_bits(fmt: ZkfFormat, value: float) -> int:
    if value == 0.0:
        return zero(fmt)
    if math.isinf(value):
        return canonical_inf(fmt, 0 if value > 0 else 1)
    sign = 0 if value > 0 else 1
    return round_fraction_to_zkf(fmt, sign, Fraction(abs(value)))


@cocotb.test()
async def const_runtime_cases(dut) -> None:
    context = float_context("const")
    fmt = ZkfFormat(context.wexp, context.wman)
    for case in CASES:
        check_width(case.port, getattr(dut, case.port), fmt.wfull, context)

    await Timer(1, unit="ns")

    for index, case in enumerate(CASES):
        handle = getattr(dut, case.port)
        assert is_resolvable(handle), (
            f"{context.prefix()} {case.port} unresolved case={index} value={case.value!r}"
        )
        observed = int(handle.value)
        expected = expected_bits(fmt, case.value)
        assert observed == expected, (
            f"{context.prefix()} {case.port} mismatch case={index} value={case.value!r} "
            f"expected={hex_bits(expected, fmt.wfull)} observed={hex_bits(observed, fmt.wfull)}"
        )
