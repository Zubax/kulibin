#!/usr/bin/env python3

from __future__ import annotations

import cocotb

from casegen import AddCase, add_cases
from cocotb_utils import (
    FixedLatencyScoreboard,
    context_from_env,
    drive_unsigned,
    env_int,
    env_str,
    run_stream_cases,
    start_clock,
)
from zkf_model import ZkfFormat


@cocotb.test()
async def add_runtime_cases(dut) -> None:
    wexp = env_int("ZKF_WEXP")
    wman = env_int("ZKF_WMAN")
    kind = env_str("ZKF_KIND", "random")
    count = env_int("ZKF_RANDOM_COUNT", 1024)
    fmt = ZkfFormat(wexp, wman)
    context = context_from_env("add")
    cases = add_cases(fmt, kind, context.seed, count)

    start_clock(dut)
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0

    scoreboard = FixedLatencyScoreboard(dut, 4, context, {"y": (dut.y, fmt.wfull)})

    def drive_case(case: AddCase) -> dict[str, int]:
        drive_unsigned(dut.a, case.a)
        drive_unsigned(dut.b, case.b)
        return {"y": case.expected}

    def invalid_drive() -> None:
        dut.in_valid.value = 0
        drive_unsigned(dut.a, (1 << fmt.wfull) - 1)
        drive_unsigned(dut.b, 0)

    def describe(index: int, case: AddCase) -> str:
        return f"case={index} {case.describe(fmt)}"

    def drive_reset_sample() -> None:
        dut.in_valid.value = 1
        drive_case(cases[0])

    await scoreboard.reset(4, drive_during_reset=drive_reset_sample)
    await run_stream_cases(dut, scoreboard, cases, drive_case, invalid_drive, describe)
    assert scoreboard.checked == len(cases), (
        f"{context.prefix()} checked {scoreboard.checked} outputs, expected {len(cases)}"
    )
