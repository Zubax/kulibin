#!/usr/bin/env python3
"""Latency formulas shared by the ZKF verification suite and synthesis reports.

The cocotb tests use these values as the scoreboard delay, so a wrong value fails
simulation. The synthesis reports import the same helpers so the published latency
is the latency verified by the test suite, not a second copy of the arithmetic.
"""

from __future__ import annotations

from zkf_trans_tables import SPECS as TRANS_SPECS
from zkf_trig_tables import SPECS as TRIG_SPECS


def _enabled(value: int) -> int:
    if value < 0:
        raise ValueError(f"stage value must be non-negative, got {value}")
    return 1 if value else 0


def _count(value: int) -> int:
    if value < 0:
        raise ValueError(f"stage count must be non-negative, got {value}")
    return value


def div_qfrac(wman: int) -> int:
    qfrac_base = wman + 2
    return qfrac_base + (qfrac_base % 2)


def pack_latency(*, stage_output: int = 0) -> int:
    return _enabled(stage_output)


def mul_latency(
    *,
    stage_input: int = 0,
    stage_product: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    # stage_product (0..3) forwards to _zkf_pmul, whose latency is 1 + stage_product, so it contributes its raw count.
    return 1 + _enabled(stage_input) + _count(stage_product) + _enabled(stage_pack) + _enabled(stage_output)


def add_latency(
    *,
    stage_input: int = 0,
    stage_decode: int = 0,
    stage_align: int = 0,
    stage_normalize: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    return (
        4
        + _enabled(stage_input)
        + _enabled(stage_decode)
        + _enabled(stage_align)
        + _count(stage_normalize)
        + _enabled(stage_pack)
        + _enabled(stage_output)
    )


def fma_latency(
    *,
    stage_input: int = 0,
    stage_product: int = 0,
    stage_decode: int = 0,
    stage_align: int = 0,
    stage_normalize: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    return (
        5
        + _enabled(stage_input)
        + _count(stage_product)  # forwards to _zkf_pmul (latency 1 + stage_product); contributes its raw count
        + _enabled(stage_decode)
        + _enabled(stage_align)
        + _count(stage_normalize)
        + _enabled(stage_pack)
        + _enabled(stage_output)
    )


def div_core_latency(wman: int) -> int:
    return 2 + (div_qfrac(wman) // 2)


def div_latency(
    wman: int,
    *,
    stage_input: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    return div_core_latency(wman) + _enabled(stage_input) + _enabled(stage_pack) + _enabled(stage_output)


def cmp_latency(*, stage_input: int = 0) -> int:
    return 1 + _enabled(stage_input)


def mul_ilog2_const_latency(*, stage_input: int = 0, stage_decode: int = 0) -> int:
    return 1 + _enabled(stage_input) + _enabled(stage_decode)


def from_int_latency(
    *,
    stage_input: int = 0,
    stage_normalize: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    return 1 + _enabled(stage_input) + _count(stage_normalize) + _enabled(stage_pack) + _enabled(stage_output)


def to_int_latency(*, stage_input: int = 0) -> int:
    return 4 + _enabled(stage_input)


def resize_latency(*, stage_input: int = 0, stage_output: int = 0) -> int:
    return _enabled(stage_input) + _enabled(stage_output)


def round_latency(*, stage_input: int = 0, stage_decode: int = 0, stage_pack: int = 0, stage_output: int = 0) -> int:
    return _enabled(stage_input) + _enabled(stage_decode) + _enabled(stage_pack) + _enabled(stage_output)


def exp2_latency(
    wman: int,
    *,
    stage_input: int = 0,
    stage_product: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    degree = TRANS_SPECS[("exp2", wman)]["d"]
    return (
        _enabled(stage_input)
        + 5
        + degree * (2 + _count(stage_product))
        + _enabled(stage_pack)
        + _enabled(stage_output)
    )


def log2_latency(
    wman: int,
    *,
    stage_input: int = 0,
    stage_product: int = 0,
    stage_normalize: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    degree = TRANS_SPECS[("log2", wman)]["d"]
    product_stages = _count(stage_product)
    return (
        _enabled(stage_input)
        + 5
        + product_stages
        + _count(stage_normalize)
        + _enabled(stage_pack)
        + degree * (2 + product_stages)
        + _enabled(stage_output)
    )


def sincos_latency(
    wman: int,
    *,
    unroll100: int = 100,
    parallel: int = 0,
    stage_input: int = 0,
    stage_output: int = 0,
    stage_product: int = 0,
    stage_normalize: int = 0,
    stage_pack: int = 0,
    **_ignored: int,
) -> int:
    # Iterative (folded) CORDIC initiation interval = latency, measured accept -> out_valid. The cocotb testbench
    # asserts the RTL matches this exactly, and the RTL LATENCY parameter (zkf_sincos.v) is the same closed form.
    # Constant 10 = 1 (R1 decode) + 1 (R2 barrel shift) + 1 (engine start) + 1 (engine done)
    #   + 4 (shared-multiply micro-sequence at STAGE_PRODUCT=0: PHI (issued on the cd_zdone cycle off cd_zn) + S/C
    #        pipelined two-deep, the C product folding straight into sin/cos; no separate PACK cycle)
    #   + 2 (always-on wide-datapath stages: octant-fold + merge-B3). The exponent decode is combinational.
    # Each STAGE_PRODUCT unit adds one cycle to PHI and one across the pipelined S/C pair = 2*STAGE_PRODUCT.
    # Then: rotation cycles = ceil(K*100/UNROLL100) (UNROLL100 = iterations/cycle x100: 50 = half-rate 2-cycle engine,
    # 100 = 1/cycle, 200/300/400 = 2/3/4 per cycle); the optional STAGE_INPUT / STAGE_OUTPUT register stages (+1 each);
    # plus STAGE_NORMALIZE + STAGE_PACK. out_ready adds nothing when held high.
    # Decoupled z-path (parallel): the z-recurrence runs at full rate (k cycles), reaching z_done ZGAP = iter_cycles - k
    # ahead of done, so PHI is issued early and its PMUL_L = 1+STAGE_PRODUCT pipeline overlaps the CORDIC; the back-end
    # skips the P_PHI wait, cutting SAVED = min(PMUL_L, ZGAP). Only legal half-rate. Mirrors ZKF_SINCOS_LATENCY exactly.
    if stage_product not in (0, 1, 2, 3, 4):
        raise ValueError(f"stage_product must be 0..4, got {stage_product}")
    if unroll100 != 50 and (unroll100 < 100 or unroll100 % 100 != 0):
        raise ValueError(f"unroll100 must be 50 or a positive multiple of 100, got {unroll100}")
    k = TRIG_SPECS[wman]["n"]
    iter_cycles = (k * 100 + unroll100 - 1) // unroll100
    saved = 0
    if parallel:
        zgap = iter_cycles - k
        pmul_l = 1 + _count(stage_product)
        saved = min(pmul_l, zgap)
    return (
        10 + 2 * _count(stage_product) + iter_cycles - saved
        + _count(stage_input) + _count(stage_output)
        + _count(stage_normalize) + _count(stage_pack)
    )


def module_latency(
    kind: str,
    *,
    wman: int = 0,
    unroll100: int = 100,
    parallel: int = 0,
    stage_input: int = 0,
    stage_product: int = 0,
    stage_align: int = 0,
    stage_decode: int = 0,
    stage_normalize: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    if kind == "pack":
        return pack_latency(stage_output=stage_output)
    if kind == "mul":
        return mul_latency(
            stage_input=stage_input,
            stage_product=stage_product,
            stage_pack=stage_pack,
            stage_output=stage_output,
        )
    if kind in {"add", "addsub"}:
        return add_latency(
            stage_input=stage_input,
            stage_decode=stage_decode,
            stage_align=stage_align,
            stage_normalize=stage_normalize,
            stage_pack=stage_pack,
            stage_output=stage_output,
        )
    if kind == "fma":
        return fma_latency(
            stage_input=stage_input,
            stage_product=stage_product,
            stage_decode=stage_decode,
            stage_align=stage_align,
            stage_normalize=stage_normalize,
            stage_pack=stage_pack,
            stage_output=stage_output,
        )
    if kind == "div_core":
        return div_core_latency(wman)
    if kind == "div":
        return div_latency(wman, stage_input=stage_input, stage_pack=stage_pack, stage_output=stage_output)
    if kind in {"cmp", "sort"}:
        return cmp_latency(stage_input=stage_input)
    if kind == "mul_ilog2_const":
        return mul_ilog2_const_latency(stage_input=stage_input, stage_decode=stage_decode)
    if kind == "from_int":
        return from_int_latency(
            stage_input=stage_input,
            stage_normalize=stage_normalize,
            stage_pack=stage_pack,
            stage_output=stage_output,
        )
    if kind == "to_int":
        return to_int_latency(stage_input=stage_input)
    if kind == "resize":
        return resize_latency(stage_input=stage_input, stage_output=stage_output)
    if kind == "round":
        return round_latency(stage_input=stage_input, stage_decode=stage_decode,
                             stage_pack=stage_pack, stage_output=stage_output)
    if kind == "exp2":
        return exp2_latency(
            wman,
            stage_input=stage_input,
            stage_product=stage_product,
            stage_pack=stage_pack,
            stage_output=stage_output,
        )
    if kind == "log2":
        return log2_latency(
            wman,
            stage_input=stage_input,
            stage_product=stage_product,
            stage_normalize=stage_normalize,
            stage_pack=stage_pack,
            stage_output=stage_output,
        )
    if kind == "sincos":
        return sincos_latency(
            wman,
            unroll100=unroll100,
            parallel=parallel,
            stage_input=stage_input,
            stage_output=stage_output,
            stage_product=stage_product,
            stage_normalize=stage_normalize,
            stage_pack=stage_pack,
        )
    raise ValueError(f"unsupported module kind: {kind}")
