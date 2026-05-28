#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass

import cocotb
import numpy as np

from zkf_model import ZkfFormat, hex_bits, log2_reference, mask, normal
from zkf_operands import directed_numbers, random_bits, random_operand
from zkf_params import check_width, float_context
from zkf_stream import RegisterStageScoreboard, drive_unsigned, run_stream_cases, start_clock


@dataclass(frozen=True)
class UnaryCase:
    label: str
    x: int
    y: int
    domain_error: int
    pole: int

    def describe(self, fmt: ZkfFormat) -> str:
        return f"{self.label} x={hex_bits(self.x, fmt.wfull)}"


def add_unique(cases: list[UnaryCase], seen: set[int], label: str, fmt: ZkfFormat, x: int) -> None:
    key = x & mask(fmt.wfull)
    if key in seen:
        return
    seen.add(key)
    y, domain_error, pole = log2_reference(fmt, x)
    cases.append(UnaryCase(label, x, y, domain_error, pole))


def directed_values(fmt: ZkfFormat) -> list[tuple[str, int]]:
    out: list[tuple[str, int]] = [
        ("raw_zero", 0),                                  # pole
        ("raw_one_frac", 1),
        ("raw_neg_zero", 1 << fmt.sign_shift),            # pole (canonicalized +0)
        ("raw_pos_inf", fmt.exp_inf << fmt.wfrac),        # +inf
        ("raw_neg_inf", (1 << fmt.sign_shift) | (fmt.exp_inf << fmt.wfrac)),  # domain error
        ("raw_all_ones", mask(fmt.wfull)),                # negative non-canonical -> domain error
    ]
    if fmt.wexp >= 3:
        for label, value in directed_numbers(fmt).items():
            out.append((f"num_{label}", value))
        # Exact powers of two: log2 is an exact integer -> exercises the frac == 0 / l == 0 paths.
        for k in (-2, -1, 0, 1, 2):
            exp = fmt.bias + k
            if 1 <= exp <= fmt.exp_max_finite:
                out.append((f"pow2_{k}", normal(fmt, 0, exp, 0)))
                out.append((f"neg_pow2_{k}", normal(fmt, 1, exp, 0)))   # negative -> domain error
        # Near 1.0 (small results, the log2 cancellation regime).
        out.append(("just_above_one", normal(fmt, 0, fmt.bias, 1)))
        out.append(("just_below_one", normal(fmt, 0, fmt.bias - 1, fmt.frac_mask)))
    return out


def cases_for(fmt: ZkfFormat, kind: str, seed: int, count: int) -> list[UnaryCase]:
    cases: list[UnaryCase] = []
    seen: set[int] = set()

    if kind == "exhaustive":
        for x in range(1 << fmt.wfull):
            add_unique(cases, seen, "exhaustive", fmt, x)
        return cases

    for label, value in directed_values(fmt):
        add_unique(cases, seen, label, fmt, value)

    if kind == "directed":
        return cases

    rng = np.random.default_rng(seed)
    while len(cases) < count:
        x = random_operand(fmt, rng) if int(rng.integers(0, 4)) else random_bits(fmt.wfull, rng)
        add_unique(cases, seen, "random", fmt, x)
    return cases


@cocotb.test()
async def log2_runtime_cases(dut) -> None:
    context = float_context("log2")
    fmt = ZkfFormat(context.wexp, context.wman)
    check_width("x", dut.x, fmt.wfull, context)
    check_width("y", dut.y, fmt.wfull, context)
    cases = cases_for(fmt, context.kind, context.seed, context.count)

    start_clock(dut)
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.x.value = 0

    from zkf_trans_tables import SPECS
    # Register stages: STAGE_INPUT + 2 ROM-read + D*(2+SP) Horner + (1+SP) final-multiply (_zkf_log2_final_mul split)
    # + (3 + STAGE_NORMALIZE) back-end + STAGE_OUTPUT.
    poly_degree = SPECS[("log2", context.wman)]["d"]
    sp, sn = context.stage_product, context.stage_normalize
    register_stages = context.stage_input + 6 + sp + sn + poly_degree * (2 + sp) + context.stage_output
    scoreboard = RegisterStageScoreboard(
        dut,
        register_stages,
        context,
        {"y": (dut.y, fmt.wfull), "domain_error": (dut.domain_error, 1), "pole": (dut.pole, 1)},
    )

    def drive_case(case: UnaryCase) -> dict[str, int]:
        drive_unsigned(dut.x, case.x)
        return {"y": case.y, "domain_error": case.domain_error, "pole": case.pole}

    def invalid_drive() -> None:
        dut.in_valid.value = 0
        drive_unsigned(dut.x, mask(fmt.wfull))

    def describe(index: int, case: UnaryCase) -> str:
        return f"case={index} {case.describe(fmt)}"

    def drive_reset_sample() -> None:
        dut.in_valid.value = 1
        drive_case(cases[0])

    await scoreboard.reset(register_stages + 1, drive_during_reset=drive_reset_sample)
    await run_stream_cases(dut, scoreboard, cases, drive_case, invalid_drive, describe)
    assert scoreboard.checked == len(cases), (
        f"{context.prefix()} checked {scoreboard.checked} outputs, expected {len(cases)}"
    )
