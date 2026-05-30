#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass

import cocotb
import numpy as np

from zkf_model import (
    ZkfFormat,
    hex_bits,
    mask,
    pack_from_mag_scale_case,
    pack_reference,
    signed_range,
)
from zkf_operands import random_pack_mag_scale
from zkf_params import check_width, float_context
from zkf_stream import RegisterStageScoreboard, drive_signed, drive_unsigned, run_stream_cases, start_clock


@dataclass(frozen=True)
class PackCase:
    label: str
    sign: int
    force_zero: int
    force_inf: int
    exp_unbiased: int
    significand: int
    guard: int
    round_bit: int
    sticky: int
    expected: int

    def describe(self, fmt: ZkfFormat) -> str:
        return (
            f"{self.label} sign={self.sign} force_zero={self.force_zero} force_inf={self.force_inf} "
            f"exp={self.exp_unbiased} sig={hex_bits(self.significand, fmt.wman)} "
            f"grs={self.guard}{self.round_bit}{self.sticky}"
        )


def make_case(
    fmt: ZkfFormat,
    label: str,
    sign: int,
    force_zero: int,
    force_inf: int,
    exp_unbiased: int,
    significand_value: int,
    guard: int,
    round_bit: int,
    sticky: int,
) -> PackCase:
    return PackCase(
        label=label,
        sign=sign,
        force_zero=force_zero,
        force_inf=force_inf,
        exp_unbiased=exp_unbiased,
        significand=significand_value,
        guard=guard,
        round_bit=round_bit,
        sticky=sticky,
        expected=pack_reference(
            fmt,
            sign,
            force_zero,
            force_inf,
            exp_unbiased,
            significand_value,
            guard,
            round_bit,
            sticky,
        ),
    )


def directed_cases(fmt: ZkfFormat) -> list[PackCase]:
    min_exp = fmt.min_exp_unbiased
    max_exp = fmt.max_exp_unbiased
    one = 1 << fmt.wfrac
    max_sig = (1 << fmt.wman) - 1
    return [
        make_case(fmt, "force_zero_wins_over_force_inf", 1, 1, 1, max_exp + 2, max_sig, 1, 1, 1),
        make_case(fmt, "force_inf_overrides_underflow", 1, 0, 1, min_exp - 3, one, 0, 0, 0),
        make_case(fmt, "below_half_min_flush", 0, 0, 0, min_exp - 2, max_sig, 1, 1, 1),
        make_case(fmt, "half_min_hidden_one_to_min", 0, 0, 0, min_exp - 1, one, 0, 0, 0),
        make_case(fmt, "one_below_min_one_and_half_to_min", 0, 0, 0, min_exp - 1, one + (one >> 1), 0, 0, 0),
        make_case(fmt, "negative_one_below_min_to_min", 1, 0, 0, min_exp - 1, max_sig - 1, 1, 0, 0),
        make_case(fmt, "negative_min_normal", 1, 0, 0, min_exp, one, 0, 0, 0),
        make_case(fmt, "tie_retained_even", 0, 0, 0, 0, one, 1, 0, 0),
        make_case(fmt, "tie_rounds_odd_up", 0, 0, 0, 0, one + 1, 1, 0, 0),
        make_case(fmt, "round_down", 0, 0, 0, 0, one + 1, 0, 1, 1),
        make_case(fmt, "round_up", 0, 0, 0, 0, one + 1, 1, 0, 1),
        make_case(fmt, "max_finite", 0, 0, 0, max_exp, max_sig, 0, 0, 0),
        make_case(fmt, "round_to_infinity", 0, 0, 0, max_exp, max_sig, 1, 0, 0),
        make_case(fmt, "explicit_overflow", 1, 0, 0, max_exp + 1, one, 0, 0, 0),
    ]


def manual_w5_m8_cases() -> list[PackCase]:
    fmt = ZkfFormat(5, 8)
    manual = [
        ("manual_zero_is_canonical", 1, 0, 31, 0x0000),
        ("manual_below_half_min_flush", 0, 511, -24, 0x0000),
        ("manual_half_min_to_min", 0, 1, -15, 0x0080),
        ("manual_one_below_min_no_carry", 0, 255, -22, 0x0080),
        ("manual_one_below_min_carry", 0, 511, -23, 0x0080),
        ("manual_negative_one_below_min_carry", 1, 511, -23, 0x1080),
        ("manual_min_normal", 0, 1, -14, 0x0080),
        ("manual_negative_min_normal", 1, 1, -14, 0x1080),
        ("manual_one", 0, 1, 0, 0x0780),
        ("manual_minus_one", 1, 1, 0, 0x1780),
        ("manual_one_and_half", 0, 3, -1, 0x07C0),
        ("manual_two", 0, 1, 1, 0x0800),
        ("manual_minus_two", 1, 1, 1, 0x1800),
        ("manual_max_sig_exp_zero", 0, 255, -7, 0x07FF),
        ("manual_round_down", 0, 513, -9, 0x0780),
        ("manual_tie_to_even_lower", 0, 514, -9, 0x0780),
        ("manual_round_up", 0, 515, -9, 0x0781),
        ("manual_tie_to_even_upper", 0, 518, -9, 0x0782),
        ("manual_below_carry_threshold", 0, 1021, -9, 0x07FF),
        ("manual_tie_carry", 0, 511, -8, 0x0800),
        ("manual_negative_tie_carry", 1, 511, -8, 0x1800),
        ("manual_high_input_bit_exact", 0, 0x8000, 0, 0x0F00),
        ("manual_round_carry_to_infinity", 0, 0xFFFF, 0, 0x0F80),
        ("manual_max_finite", 0, 255, 8, 0x0F7F),
        ("manual_above_max_rounds_to_max", 0, 1021, 6, 0x0F7F),
        ("manual_round_to_infinity_tie", 0, 511, 7, 0x0F80),
        ("manual_negative_round_to_infinity_tie", 1, 511, 7, 0x1F80),
        ("manual_exponent_overflow", 0, 1, 16, 0x0F80),
    ]
    cases = []
    for label, sign, mag, scale, expected in manual:
        case = make_case(fmt, label, *pack_from_mag_scale_case(fmt, sign, mag, scale))
        if case.expected != expected:
            raise AssertionError(f"{label}: expected {expected:04x}, model returned {case.expected:04x}")
        cases.append(case)
    return cases


def exhaustive_cases(fmt: ZkfFormat, wexp_unbiased: int, exp_is_biased: int = 0) -> list[PackCase]:
    cases: list[PackCase] = []
    for sign in (0, 1):
        for force_zero in (0, 1):
            for force_inf in (0, 1):
                for exp_field in signed_range(wexp_unbiased):
                    # In biased mode the DUT consumes this field directly as the signed biased exponent, so iterate the
                    # field and recover the unbiased value the reference expects; drive_case re-adds the bias on drive.
                    exp_unbiased = exp_field - fmt.bias if exp_is_biased else exp_field
                    for significand_value in range(1 << fmt.wman):
                        for grs in range(8):
                            cases.append(
                                make_case(
                                    fmt,
                                    "exhaustive",
                                    sign,
                                    force_zero,
                                    force_inf,
                                    exp_unbiased,
                                    significand_value,
                                    (grs >> 2) & 1,
                                    (grs >> 1) & 1,
                                    grs & 1,
                                )
                            )
    return cases


def _filter_no_overflow(fmt: ZkfFormat, cases: list[PackCase], assume_no_overflow: int) -> list[PackCase]:
    if not assume_no_overflow:
        return cases
    # Under ASSUME_NO_OVERFLOW=1 the packer prunes its overflow detector, so its result diverges from the
    # overflow-detecting reference only for a genuine exponent overflow with no force flag: force_inf / force_zero
    # dominate (converge), and a round-carry from EXP_MAX_FINITE up to EXP_INF rides the rounding adder, not the
    # detector (converges). An exp_unbiased strictly above the finite range is the caller's-responsibility / undefined
    # region for this mode, so drop it from the stimulus.
    return [
        case for case in cases
        if case.force_inf or case.force_zero or case.exp_unbiased <= fmt.max_exp_unbiased
    ]


def cases_for(
    fmt: ZkfFormat, kind: str, seed: int, count: int, wexp_unbiased: int,
    exp_is_biased: int = 0, assume_no_overflow: int = 0,
) -> list[PackCase]:
    if kind == "exhaustive":
        return _filter_no_overflow(fmt, exhaustive_cases(fmt, wexp_unbiased, exp_is_biased), assume_no_overflow)
    if exp_is_biased:
        # The directed/random generators choose unbiased exponents around the format's range; re-biasing those for the
        # EXP_IS_BIASED port can exceed the signed field, so EXP_IS_BIASED=1 is only swept with the exhaustive kind.
        raise ValueError("EXP_IS_BIASED=1 pack stimulus is only generated for the exhaustive kind")

    cases = directed_cases(fmt)
    if (fmt.wexp, fmt.wman) == (5, 8):
        cases.extend(manual_w5_m8_cases())
    if kind == "directed":
        return _filter_no_overflow(fmt, cases, assume_no_overflow)

    rng = np.random.default_rng(seed)
    seen = {
        (
            case.sign,
            case.force_zero,
            case.force_inf,
            case.exp_unbiased,
            case.significand,
            case.guard,
            case.round_bit,
            case.sticky,
        )
        for case in cases
    }
    while len(cases) < count:
        args = pack_from_mag_scale_case(fmt, *random_pack_mag_scale(fmt, rng))
        if args in seen:
            continue
        seen.add(args)
        cases.append(make_case(fmt, "random_mag_scale", *args))
    return _filter_no_overflow(fmt, cases, assume_no_overflow)


@cocotb.test()
async def pack_runtime_cases(dut) -> None:
    context = float_context("pack", require_wexp_unbiased=True)
    fmt = ZkfFormat(context.wexp, context.wman)
    wexp_unbiased = context.wexp_unbiased
    assert wexp_unbiased is not None

    check_width("y", dut.y, fmt.wfull, context)
    check_width("significand", dut.significand, fmt.wman, context)
    check_width("exp_unbiased", dut.exp_unbiased, wexp_unbiased, context)
    exp_is_biased = context.exp_is_biased
    assume_no_overflow = context.assume_no_overflow
    cases = cases_for(
        fmt, context.kind, context.seed, context.count, wexp_unbiased, exp_is_biased, assume_no_overflow
    )

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

    register_stages = context.stage_output
    scoreboard = RegisterStageScoreboard(dut, register_stages, context, {"y": (dut.y, fmt.wfull)})

    def drive_case(case: PackCase) -> dict[str, int]:
        dut.sign.value = case.sign
        dut.force_zero.value = case.force_zero
        dut.force_inf.value = case.force_inf
        # EXP_IS_BIASED=1 expects the already-biased exponent on the port; the exhaustive generator chose exp_unbiased
        # so that exp_unbiased + bias stays inside the signed field.
        drive_signed(dut.exp_unbiased, case.exp_unbiased + (fmt.bias if exp_is_biased else 0))
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
        drive_unsigned(dut.significand, (1 << fmt.wman) - 1)
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
