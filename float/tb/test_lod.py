#!/usr/bin/env python3
"""Standalone bench for the leading-one detector _zkf_lod.

_zkf_lod is a shared helper (used by zkf_add/zkf_addsub/zkf_from_int) that previously had no dedicated
test - it was only exercised embedded, where the callers drive it with narrow, zero-padded inputs that
never set the high leaves. This bench drives x exhaustively at small widths so every reachable tree
node toggles, and checks (zero, shamt) against the model.
"""

from __future__ import annotations

import cocotb
import numpy as np
from cocotb.triggers import Timer

from zkf_model import lod_reference, mask
from zkf_params import plusarg_int, plusarg_str
from zkf_stream import drive_unsigned, is_resolvable


def cases_for(width: int, kind: str, seed: int, count: int) -> list[int]:
    if kind == "exhaustive":
        # Trailing 0 after the all-ones value so every input bit also toggles 1->0 (a monotonic
        # 0..2^W-1 sweep ends high and would leave the MSB's down-toggle uncovered).
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
async def lod_runtime_cases(dut) -> None:
    width = plusarg_int("ZKF_LOD_W")
    kind = plusarg_str("ZKF_KIND", "exhaustive")
    seed = plusarg_int("ZKF_SEED", 0)
    count = plusarg_int("ZKF_COUNT", 0)
    cfg = plusarg_str("ZKF_CONFIG", "default")
    if len(dut.x) != width:
        raise AssertionError(f"{cfg}: x width {len(dut.x)} != ZKF_LOD_W={width}")

    cases = cases_for(width, kind, seed, count)
    checked = 0
    for x in cases:
        drive_unsigned(dut.x, x)
        await Timer(1, unit="ns")
        exp_zero, exp_shamt = lod_reference(width, x)
        assert is_resolvable(dut.zero), f"{cfg}: zero unresolved x={x:#x}"
        obs_zero = int(dut.zero.value)
        assert obs_zero == exp_zero, f"{cfg}: zero mismatch x={x:#x} got={obs_zero} exp={exp_zero}"
        if not exp_zero:
            assert is_resolvable(dut.shamt), f"{cfg}: shamt unresolved x={x:#x}"
            obs_shamt = int(dut.shamt.value)
            assert obs_shamt == exp_shamt, (
                f"{cfg}: shamt mismatch x={x:#x} got={obs_shamt} exp={exp_shamt} (W={width})"
            )
        checked += 1
    assert checked == len(cases), f"{cfg}: checked {checked} of {len(cases)}"
