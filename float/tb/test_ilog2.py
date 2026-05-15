#!/usr/bin/env python3

from __future__ import annotations

import cocotb
from cocotb.triggers import Timer

from casegen import ilog2_cases
from cocotb_utils import context_from_env, drive_unsigned, env_int, is_resolvable
from zkf_model import hex_bits


@cocotb.test()
async def ilog2_floor_runtime_cases(dut) -> None:
    width = env_int("ZKF_WIDTH")
    count = env_int("ZKF_RANDOM_COUNT", 512)
    context = context_from_env("ilog2")
    cases = ilog2_cases(width, context.seed, count)

    for index, case in enumerate(cases):
        drive_unsigned(dut.x, case.x)
        await Timer(1, unit="ns")
        assert is_resolvable(dut.zero), f"{context.prefix()} case={index} {case.label} zero is unresolved"
        assert is_resolvable(dut.y), f"{context.prefix()} case={index} {case.label} y is unresolved"
        observed_zero = int(dut.zero.value)
        observed_y = int(dut.y.value)
        assert observed_zero == case.expected_zero, (
            f"{context.prefix()} case={index} {case.label} x={hex_bits(case.x, width)} "
            f"zero expected={case.expected_zero} observed={observed_zero}"
        )
        assert observed_y == case.expected_y, (
            f"{context.prefix()} case={index} {case.label} x={hex_bits(case.x, width)} "
            f"y expected={case.expected_y} observed={observed_y}"
        )
