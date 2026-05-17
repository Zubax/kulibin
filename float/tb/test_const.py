#!/usr/bin/env python3
"""Cocotb test for zkf_const, driven through the auto-generated zkf_const_wrap harness."""

from __future__ import annotations

from fractions import Fraction

import cocotb
from cocotb.triggers import Timer

from zkf_const_cases import FINITE_VALUES, INF_SIGNS
from zkf_model import ZkfFormat, canonical_inf, hex_bits, round_fraction_to_zkf, zero
from zkf_params import check_width, float_context
from zkf_stream import is_resolvable


def expected_finite(fmt: ZkfFormat, value: float) -> int:
    # zkf_const collapses signed zero to canonical +0; cases.py uses only nonzero finites,
    # but defend against future additions.
    if value == 0.0:
        return zero(fmt)
    sign = 0 if value > 0 else 1
    return round_fraction_to_zkf(fmt, sign, Fraction(abs(value)))


def expected_inf(fmt: ZkfFormat, inf_sign: int) -> int:
    return canonical_inf(fmt, 0 if inf_sign > 0 else 1)


def slice_bits(bus_value: int, index: int, width: int) -> int:
    return (bus_value >> (index * width)) & ((1 << width) - 1)


@cocotb.test()
async def const_runtime_cases(dut) -> None:
    context = float_context("const")
    fmt = ZkfFormat(context.wexp, context.wman)

    check_width("y_zero",     dut.y_zero,     fmt.wfull, context)
    check_width("y_neg_zero", dut.y_neg_zero, fmt.wfull, context)
    check_width("y_finite",   dut.y_finite,   len(FINITE_VALUES) * fmt.wfull, context)
    check_width("y_inf",      dut.y_inf,      len(INF_SIGNS)     * fmt.wfull, context)

    await Timer(1, unit="ns")

    # Zero ports: both +0.0 and -0.0 in the wrap must decode to canonical +0 bits.
    for port in ("y_zero", "y_neg_zero"):
        handle = getattr(dut, port)
        assert is_resolvable(handle), f"{context.prefix()} {port} unresolved"
        observed = int(handle.value)
        expected = zero(fmt)
        assert observed == expected, (
            f"{context.prefix()} {port} mismatch "
            f"expected={hex_bits(expected, fmt.wfull)} observed={hex_bits(observed, fmt.wfull)}"
        )

    # Finite VALUE-driven bus.
    assert is_resolvable(dut.y_finite), f"{context.prefix()} y_finite unresolved"
    finite_bus = int(dut.y_finite.value)
    for index, value in enumerate(FINITE_VALUES):
        observed = slice_bits(finite_bus, index, fmt.wfull)
        expected = expected_finite(fmt, value)
        assert observed == expected, (
            f"{context.prefix()} y_finite[{index}] value={value!r} mismatch "
            f"expected={hex_bits(expected, fmt.wfull)} observed={hex_bits(observed, fmt.wfull)}"
        )

    # INF-parameter bus.
    assert is_resolvable(dut.y_inf), f"{context.prefix()} y_inf unresolved"
    inf_bus = int(dut.y_inf.value)
    for index, inf_sign in enumerate(INF_SIGNS):
        observed = slice_bits(inf_bus, index, fmt.wfull)
        expected = expected_inf(fmt, inf_sign)
        assert observed == expected, (
            f"{context.prefix()} y_inf[{index}] inf={inf_sign:+d} mismatch "
            f"expected={hex_bits(expected, fmt.wfull)} observed={hex_bits(observed, fmt.wfull)}"
        )
