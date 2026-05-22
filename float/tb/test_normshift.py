#!/usr/bin/env python3
"""Standalone bench for the fused leading-zero-normalizing shifter _zkf_normshift.

_zkf_normshift replaced the former _zkf_lod-plus-separate-barrel-shift pair shared by zkf_add and
zkf_from_int. Embedded callers drive it with narrow, zero-padded inputs over a limited leading-one
range, so this bench sweeps x exhaustively at small widths (so every reachable cascade node toggles)
and checks (zero, count, y) against the model, for both STAGE_SPLIT polarities.
"""

from __future__ import annotations

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge, Timer

from zkf_model import mask, normshift_reference
from zkf_params import plusarg_int, plusarg_str
from zkf_stream import drive_unsigned, is_resolvable, start_clock


def cases_for(width: int, kind: str, seed: int, count: int) -> list[int]:
    if kind == "exhaustive":
        # Trailing 0 after the all-ones value so every input bit also toggles 1->0.
        return list(range(1 << width)) + [0]
    xs = {0, 1, 1 << (width - 1), mask(width)}
    xs.update(1 << i for i in range(width))           # one-hot (each leading-one position)
    xs.update((1 << i) - 1 for i in range(1, width + 1))
    if kind == "directed":
        return sorted(xs)
    rng = np.random.default_rng(seed)
    while len(xs) < max(count, len(xs) + 1):
        xs.add(int(rng.integers(0, 1 << width)))
    return sorted(xs)


@cocotb.test()
async def normshift_runtime_cases(dut) -> None:
    width = plusarg_int("ZKF_NS_W")
    split = plusarg_int("ZKF_NS_SPLIT", 0)
    kind = plusarg_str("ZKF_KIND", "exhaustive")
    seed = plusarg_int("ZKF_SEED", 0)
    count = plusarg_int("ZKF_COUNT", 0)
    cfg = plusarg_str("ZKF_CONFIG", "default")
    if len(dut.x) != width:
        raise AssertionError(f"{cfg}: x width {len(dut.x)} != ZKF_NS_W={width}")

    cases = cases_for(width, kind, seed, count)
    start_clock(dut)
    checked = 0
    for x in cases:
        drive_unsigned(dut.x, x)
        # Settle the combinational path (the result for STAGE_SPLIT=0), then advance `split` real clock
        # edges holding x stable across the cascade-internal register barrier. Settling before the first
        # edge avoids a t=0 drive/clock race on the un-reset datapath register.
        await Timer(1, unit="ns")
        for _ in range(split):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
        exp_zero, exp_count, exp_y = normshift_reference(width, x)
        assert is_resolvable(dut.zero), f"{cfg}: zero unresolved x={x:#x}"
        obs_zero = int(dut.zero.value)
        assert obs_zero == exp_zero, f"{cfg}: zero mismatch x={x:#x} got={obs_zero} exp={exp_zero}"
        if not exp_zero:
            assert is_resolvable(dut.count), f"{cfg}: count unresolved x={x:#x}"
            obs_count = int(dut.count.value)
            assert obs_count == exp_count, (
                f"{cfg}: count mismatch x={x:#x} got={obs_count} exp={exp_count} (W={width} split={split})"
            )
            assert is_resolvable(dut.y), f"{cfg}: y unresolved x={x:#x}"
            obs_y = int(dut.y.value)
            assert obs_y == exp_y, (
                f"{cfg}: y mismatch x={x:#x} got={obs_y:#x} exp={exp_y:#x} (W={width} split={split})"
            )
        checked += 1
    assert checked == len(cases), f"{cfg}: checked {checked} of {len(cases)}"
