#!/usr/bin/env python3

from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, Timer

from cocotb_utils import (
    RegisterStageScoreboard,
    context_from_env,
    drive_unsigned,
    env_int,
    is_resolvable,
    start_clock,
)


@cocotb.test()
async def pipe_runtime_cases(dut) -> None:
    width = env_int("ZKF_PIPE_W")
    stages = env_int("ZKF_PIPE_N")
    sample_count = env_int("ZKF_PIPE_COUNT", 64)
    context = context_from_env("pipe")

    in_handle = dut["in"]
    start_clock(dut)
    dut.rst.value = 1
    dut.in_valid.value = 0
    drive_unsigned(in_handle, 0)

    if stages == 0:
        # Pure combinational passthrough. clk/rst inputs are tied off in g_passthrough.
        for _ in range(2):
            await RisingEdge(dut.clk)
        dut.rst.value = 0
        for i in range(sample_count):
            value = ((i * 0xA5) + 1) & ((1 << width) - 1)
            valid = (i % 3) != 0
            dut.in_valid.value = valid
            drive_unsigned(in_handle, value)
            await Timer(1, unit="ns")
            assert is_resolvable(dut.out_valid), context.prefix() + " out_valid unresolved"
            observed_valid = int(dut.out_valid.value)
            assert observed_valid == int(valid), (
                f"{context.prefix()} passthrough out_valid mismatch i={i} expected={int(valid)} "
                f"observed={observed_valid}"
            )
            if valid:
                observed = int(dut.out.value)
                assert observed == value, (
                    f"{context.prefix()} passthrough out mismatch i={i} expected={value:0{(width+3)//4}x} "
                    f"observed={observed:0{(width+3)//4}x}"
                )
            await RisingEdge(dut.clk)
        return

    # Registered variant: N register stages between input and output. Reset only zeros the validity vector.
    register_stages = stages
    scoreboard = RegisterStageScoreboard(
        dut,
        register_stages,
        context,
        {"out": (dut.out, width)},
    )

    def drive_idx(i: int) -> int:
        return ((i * 0xCAFE_BABE) ^ ((i + 1) * 0x9E37_79B9)) & ((1 << width) - 1)

    def drive_during_reset() -> None:
        dut.in_valid.value = 1
        drive_unsigned(in_handle, 0xDEAD_BEEF & ((1 << width) - 1))

    await scoreboard.reset(register_stages + 2, drive_during_reset=drive_during_reset)

    # Stream a known sequence and assert the N-cycle delay holds.
    for i in range(sample_count):
        value = drive_idx(i)
        dut.in_valid.value = 1
        drive_unsigned(in_handle, value)
        await scoreboard.tick({"out": value}, f"i={i} value={value:0{(width+3)//4}x}")

    # Drain the pipeline by driving in_valid=0; outputs should all be invalid afterwards.
    dut.in_valid.value = 0
    drive_unsigned(in_handle, 0)
    for flush_index in range(register_stages + 2):
        await scoreboard.tick(None, f"flush={flush_index}")

    assert scoreboard.checked >= sample_count, (
        f"{context.prefix()} checked {scoreboard.checked} outputs, expected at least {sample_count}"
    )

    # Fill the pipeline with valid samples, then assert rst and verify out_valid is held at 0
    # for several cycles. Reset must zero only the validity bits per the project reset strategy.
    for i in range(register_stages):
        dut.in_valid.value = 1
        drive_unsigned(in_handle, drive_idx(100 + i))
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")

    dut.rst.value = 1
    dut.in_valid.value = 0
    drive_unsigned(in_handle, 0)
    for cycle in range(register_stages + 2):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert is_resolvable(dut.out_valid), context.prefix() + f" out_valid unresolved during reset cycle={cycle}"
        assert int(dut.out_valid.value) == 0, (
            f"{context.prefix()} reset failed to clear out_valid cycle={cycle}"
        )
    dut.rst.value = 0
