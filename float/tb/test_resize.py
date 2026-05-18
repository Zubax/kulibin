#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass

import cocotb
import numpy as np

from zkf_model import ZkfFormat, hex_bits, mask, resize_reference
from zkf_operands import (
    directed_numbers,
    random_inf,
    random_normal,
    random_normal_near,
    random_operand,
    random_zero,
)
from zkf_params import check_width, resize_context
from zkf_stream import RegisterStageScoreboard, drive_unsigned, run_stream_cases, start_clock


@dataclass(frozen=True)
class ResizeCase:
    label: str
    a: int
    expected: int

    def describe(self, fmt_in: ZkfFormat, fmt_out: ZkfFormat) -> str:
        return (
            f"{self.label} a={hex_bits(self.a, fmt_in.wfull)} "
            f"expected={hex_bits(self.expected, fmt_out.wfull)}"
        )


def add_unique(
    cases: list[ResizeCase],
    seen: set[int],
    label: str,
    fmt_in: ZkfFormat,
    fmt_out: ZkfFormat,
    a: int,
) -> None:
    key = a & mask(fmt_in.wfull)
    if key in seen:
        return
    seen.add(key)
    cases.append(ResizeCase(label, key, resize_reference(fmt_in, fmt_out, key)))


def directed_case_inputs(fmt_in: ZkfFormat) -> list[tuple[str, int]]:
    cases: list[tuple[str, int]] = []
    if fmt_in.wexp >= 3:
        for label, value in directed_numbers(fmt_in).items():
            cases.append((label, value))
    # Raw boundary patterns that exercise canonicalization regardless of WEXP.
    cases.extend(
        [
            ("raw_zero_clean", 0),
            ("raw_zero_neg_payload", 1 << fmt_in.sign_shift),
            ("raw_zero_payload", min(fmt_in.frac_mask, 1)),
            ("raw_inf_pos", fmt_in.exp_inf << fmt_in.wfrac),
            ("raw_inf_neg", (1 << fmt_in.sign_shift) | (fmt_in.exp_inf << fmt_in.wfrac)),
            ("raw_inf_noncanonical_pos", (fmt_in.exp_inf << fmt_in.wfrac) | min(fmt_in.frac_mask, 1)),
            ("raw_inf_noncanonical_neg", mask(fmt_in.wfull)),
        ]
    )
    return cases


def random_case(fmt_in: ZkfFormat, rng: np.random.Generator) -> int:
    mode = int(rng.integers(0, 9))
    if mode == 0:
        return random_zero(fmt_in, rng)
    if mode == 1:
        return random_inf(fmt_in, rng)
    if mode == 2:
        return random_normal_near(fmt_in, rng, [1, 2, 3], [0, 1, fmt_in.frac_mask])
    if mode == 3:
        return random_normal_near(
            fmt_in,
            rng,
            [fmt_in.bias - 1, fmt_in.bias, fmt_in.bias + 1],
            [0, 1, fmt_in.frac_mask],
        )
    if mode == 4:
        return random_normal_near(
            fmt_in,
            rng,
            [fmt_in.exp_max_finite - 2, fmt_in.exp_max_finite - 1, fmt_in.exp_max_finite],
            [0, 1 << (fmt_in.wfrac - 1), fmt_in.frac_mask],
        )
    if mode == 5:
        return random_normal(fmt_in, rng)
    return random_operand(fmt_in, rng)


def cases_for(
    fmt_in: ZkfFormat,
    fmt_out: ZkfFormat,
    kind: str,
    seed: int,
    count: int,
) -> list[ResizeCase]:
    cases: list[ResizeCase] = []
    seen: set[int] = set()

    if kind == "exhaustive":
        for a in range(1 << fmt_in.wfull):
            add_unique(cases, seen, "exhaustive", fmt_in, fmt_out, a)
        return cases

    for label, a in directed_case_inputs(fmt_in):
        add_unique(cases, seen, label, fmt_in, fmt_out, a)

    if kind == "directed":
        return cases

    rng = np.random.default_rng(seed)
    while len(cases) < count:
        a = random_case(fmt_in, rng)
        add_unique(cases, seen, "random", fmt_in, fmt_out, a)
    return cases


@cocotb.test()
async def resize_runtime_cases(dut) -> None:
    context = resize_context("resize")
    fmt_in  = ZkfFormat(context.wexp_in,  context.wman_in)
    fmt_out = ZkfFormat(context.wexp_out, context.wman_out)

    check_width("a", dut.a, fmt_in.wfull, context)
    check_width("y", dut.y, fmt_out.wfull, context)
    cases = cases_for(fmt_in, fmt_out, context.kind, context.seed, context.count)

    start_clock(dut)
    dut.rst.value = 1
    dut.in_valid.value = 0
    drive_unsigned(dut.a, 0)

    # zkf_resize uses 1 stage on the widen-only fast path (output covers input in both
    # dimensions) and 2 stages when the value must flow through _zkf_pack for rounding or
    # overflow handling.
    widen_only = (fmt_out.wman >= fmt_in.wman) and (fmt_out.wexp >= fmt_in.wexp)
    register_stages = 1 if widen_only else 2
    scoreboard = RegisterStageScoreboard(dut, register_stages, context, {"y": (dut.y, fmt_out.wfull)})

    def drive_case(case: ResizeCase) -> dict[str, int]:
        drive_unsigned(dut.a, case.a)
        return {"y": case.expected}

    def invalid_drive() -> None:
        dut.in_valid.value = 0
        drive_unsigned(dut.a, (1 << fmt_in.wfull) - 1)

    def describe(index: int, case: ResizeCase) -> str:
        return f"case={index} {case.describe(fmt_in, fmt_out)}"

    def drive_reset_sample() -> None:
        dut.in_valid.value = 1
        drive_case(cases[0])

    await scoreboard.reset(register_stages + 1, drive_during_reset=drive_reset_sample)
    await run_stream_cases(dut, scoreboard, cases, drive_case, invalid_drive, describe)
    assert scoreboard.checked == len(cases), (
        f"{context.prefix()} checked {scoreboard.checked} outputs, expected {len(cases)}"
    )
