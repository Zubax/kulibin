#!/usr/bin/env python3
"""Algebraic-property simulation tests.

Complement to the formal proofs under float/proof/ and to the per-module test_*.py files. Where the
per-module tests compare DUT outputs against a Python golden reference, these tests exercise
self-consistency properties that hold for any correct implementation regardless of the model. That
makes them a useful sanity check against the unlikely case where both the model and the RTL share a
bug.

The test scaffolding picks a property based on the DUT's port shape, so a single file works for any
binary toplevel that exposes (clk, rst, in_valid, a, b, out_valid, y) — currently zkf_mul, zkf_add,
zkf_addsub. The property exercised is commutativity:  op(a, b) == op(b, a).

The FuseSoC sim_properties_<op>_<sim> targets parameterize this with the standard ZKF_* matrix.
"""

from __future__ import annotations

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge, Timer

from zkf_model import ZkfFormat, hex_bits
from zkf_operands import directed_numbers, random_operand
from zkf_params import check_width, float_context
from zkf_stream import drive_unsigned, is_resolvable, start_clock


def operand_pairs(fmt: ZkfFormat, seed: int, count: int) -> list[tuple[int, int]]:
    rng = np.random.default_rng(seed)
    pairs: list[tuple[int, int]] = []
    if fmt.wexp >= 3:
        directed = list(directed_numbers(fmt).values())
        for a in directed:
            for b in directed:
                pairs.append((a, b))
    while len(pairs) < count:
        pairs.append((random_operand(fmt, rng), random_operand(fmt, rng)))
    return pairs[: max(count, len(pairs))]


async def reset_dut(dut, stages: int) -> None:
    dut.rst.value = 1
    dut.in_valid.value = 0
    drive_unsigned(dut.a, 0)
    drive_unsigned(dut.b, 0)
    if hasattr(dut, "op_sub"):
        dut.op_sub.value = 0
    for _ in range(stages + 2):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def drive_and_capture(dut, a: int, b: int, stages: int) -> int:
    """Drive (a, b) one cycle; expect out_valid=1 after exactly `stages` clock edges."""
    drive_unsigned(dut.a, a)
    drive_unsigned(dut.b, b)
    if hasattr(dut, "op_sub"):
        dut.op_sub.value = 0
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.in_valid.value = 0
    drive_unsigned(dut.a, 0)
    drive_unsigned(dut.b, 0)
    for _ in range(stages - 1):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    assert is_resolvable(dut.out_valid), "out_valid is unresolved at expected result cycle"
    assert int(dut.out_valid.value) == 1, "out_valid was not asserted at expected result cycle"
    assert is_resolvable(dut.y), "y is unresolved at expected result cycle"
    return int(dut.y.value)


def infer_stages(dut) -> int:
    """Map module name → pipeline depth. Knobs are simply hardcoded here for the supported toplevels."""
    name = str(dut._name)
    if "mul" in name:
        return 3
    if "addsub" in name:
        return 6
    if "add" in name:
        return 6
    raise RuntimeError(f"unknown toplevel for property test: {name}")


@cocotb.test()
async def commutativity(dut) -> None:
    context = float_context("properties")
    fmt = ZkfFormat(context.wexp, context.wman)
    check_width("a", dut.a, fmt.wfull, context)
    check_width("b", dut.b, fmt.wfull, context)
    check_width("y", dut.y, fmt.wfull, context)
    stages = infer_stages(dut)

    start_clock(dut)
    await reset_dut(dut, stages)

    pairs = operand_pairs(fmt, context.seed, max(64, context.count or 64))
    failures = 0
    for index, (a, b) in enumerate(pairs):
        y_ab = await drive_and_capture(dut, a, b, stages)
        y_ba = await drive_and_capture(dut, b, a, stages)
        if y_ab != y_ba:
            failures += 1
            if failures <= 5:
                cocotb.log.error(
                    f"commutativity violation #{index}: "
                    f"a={hex_bits(a, fmt.wfull)} b={hex_bits(b, fmt.wfull)} "
                    f"y_ab={hex_bits(y_ab, fmt.wfull)} y_ba={hex_bits(y_ba, fmt.wfull)}"
                )
    assert failures == 0, (
        f"{context.prefix()} found {failures} commutativity violation(s); first five logged above"
    )
