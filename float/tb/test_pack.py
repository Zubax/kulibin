#!/usr/bin/env python3

from __future__ import annotations

import cocotb

from casegen import PackCase, pack_cases
from cocotb_utils import (
    RegisterStageScoreboard,
    context_from_env,
    drive_signed,
    drive_unsigned,
    env_int,
    env_str,
    run_stream_cases,
    start_clock,
)
from zkf_model import ZkfFormat


@cocotb.test()
async def pack_runtime_cases(dut) -> None:
    wexp = env_int("ZKF_WEXP")
    wman = env_int("ZKF_WMAN")
    wunbiased = env_int("ZKF_WEXP_UNBIASED", wexp + 2)
    kind = env_str("ZKF_KIND", "random")
    count = env_int("ZKF_RANDOM_COUNT", 1024)
    fmt = ZkfFormat(wexp, wman)
    context = context_from_env("pack")
    cases = pack_cases(fmt, kind, context.seed, count, wunbiased)

    start_clock(dut)
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.sign.value = 0
    dut.force_zero.value = 0
    dut.force_inf.value = 0
    drive_signed(dut.exp_unbiased, 0)
    dut.significand.value = 0
    dut.guard.value = 0
    dut.round.value = 0
    dut.sticky.value = 0

    register_stages = 2
    scoreboard = RegisterStageScoreboard(dut, register_stages, context, {"y": (dut.y, fmt.wfull)})

    def drive_case(case: PackCase) -> dict[str, int]:
        dut.sign.value = case.sign
        dut.force_zero.value = case.force_zero
        dut.force_inf.value = case.force_inf
        drive_signed(dut.exp_unbiased, case.exp_unbiased)
        drive_unsigned(dut.significand, case.significand)
        dut.guard.value = case.guard
        dut.round.value = case.round_bit
        dut.sticky.value = case.sticky
        return {"y": case.expected}

    def invalid_drive() -> None:
        dut.in_valid.value = 0
        dut.sign.value = 1
        dut.force_zero.value = 0
        dut.force_inf.value = 1
        drive_signed(dut.exp_unbiased, -1)
        drive_unsigned(dut.significand, (1 << wman) - 1)
        dut.guard.value = 1
        dut.round.value = 1
        dut.sticky.value = 1

    def describe(index: int, case: PackCase) -> str:
        return f"case={index} {case.describe(fmt)}"

    def drive_reset_sample() -> None:
        dut.in_valid.value = 1
        drive_case(cases[0])

    await scoreboard.reset(register_stages + 1, drive_during_reset=drive_reset_sample)
    await run_stream_cases(dut, scoreboard, cases, drive_case, invalid_drive, describe)
    assert scoreboard.checked == len(cases), (
        f"{context.prefix()} checked {scoreboard.checked} outputs, expected {len(cases)}"
    )
