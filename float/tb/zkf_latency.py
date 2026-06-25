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
    # stage_product (0..4) forwards to _zkf_pmul, whose latency is 1 + stage_product, so it contributes its raw count.
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
    stage_reduce: int = 0,
    stage_product: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    degree = TRANS_SPECS[("exp2", wman)]["d"]
    product_stages = _count(stage_product)
    return (
        _enabled(stage_input)
        + _enabled(stage_reduce)
        + 4
        + degree * (2 + product_stages)
        + _enabled(stage_pack)
        + _enabled(stage_output)
    )


def log2_latency(
    wman: int,
    *,
    stage_input: int = 0,
    stage_decode: int = 0,
    stage_product: int = 0,
    stage_product_final: int | None = None,
    stage_normalize: int = 0,
    stage_normalize_output: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
) -> int:
    degree = TRANS_SPECS[("log2", wman)]["d"]
    product_stages = _count(stage_product)
    final_product_raw = stage_product if stage_product_final in (None, -1) else stage_product_final
    final_product_stages = _count(final_product_raw)
    return (
        _enabled(stage_input)
        + _enabled(stage_decode)
        + 5
        + final_product_stages
        + _count(stage_normalize)
        + _enabled(stage_normalize_output)
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
    # Constant 11 = 1 (R1 decode) + 1 (R2 barrel shift) + 1 (engine start) + 1 (engine done)
    #   + 4 (shared-multiply micro-sequence at STAGE_PRODUCT=0: PHI (issued on the cd_zdone cycle off cd_zn) + S/C
    #        pipelined two-deep, the C product folding straight into sin/cos; no separate PACK cycle)
    #   + 2 (always-on wide-datapath stages: octant-fold + merge-B3)
    #   + 1 (shared fixed-to-float back-end issues cos one cycle after sin). The exponent decode is combinational.
    # Each STAGE_PRODUCT unit adds one cycle to PHI and one across the pipelined S/C pair = 2*STAGE_PRODUCT.
    # Then: rotation cycles = ceil(K*100/UNROLL100) (UNROLL100 = iterations/cycle x100: 50 = half-rate 2-cycle engine,
    # 100 = 1/cycle, 200/300/400 = 2/3/4 per cycle); the optional STAGE_INPUT / STAGE_OUTPUT register stages (+1 each);
    # plus STAGE_NORMALIZE + STAGE_PACK. out_ready adds nothing when held high.
    # Decoupled z-path (parallel): the z-recurrence runs at full rate (k cycles), reaching z_done ZGAP = iter_cycles - k
    # ahead of done, so PHI is issued early and its PMUL_L = 1+STAGE_PRODUCT pipeline overlaps the CORDIC; the back-end
    # skips the P_PHI wait, cutting SAVED = min(PMUL_L, ZGAP). Only legal half-rate. Mirrors zkf_sincos LATENCY_REF.
    if stage_product not in (0, 1, 2, 3, 4):
        raise ValueError(f"stage_product must be 0..4, got {stage_product}")
    if unroll100 != 50 and (unroll100 < 100 or unroll100 % 100 != 0):
        raise ValueError(f"unroll100 must be 50 or a positive multiple of 100, got {unroll100}")
    k = TRIG_SPECS[wman]["n_sincos"]                       # sincos iteration count (== table n today)
    iter_cycles = (k * 100 + unroll100 - 1) // unroll100
    saved = 0
    if parallel:
        zgap = iter_cycles - k
        pmul_l = 1 + _count(stage_product)
        saved = min(pmul_l, zgap)
    return (
        11 + 2 * _count(stage_product) + iter_cycles - saved
        + _count(stage_input) + _count(stage_output)
        + _count(stage_normalize) + _count(stage_pack)
    )


def atan2_latency(
    wman: int,
    *,
    unroll100: int = 100,
    stage_input: int = 0,
    stage_product: int = 0,
    stage_normalize: int = 0,
    stage_pack: int = 0,
    stage_output: int = 0,
    **_ignored: int,
) -> int:
    # Iterative vectoring-CORDIC initiation interval = latency, measured accept -> out_valid. The cocotb testbench
    # asserts the RTL matches this exactly, and the RTL LATENCY parameter (zkf_atan2.v) is the same closed form.
    # Constant 8 = the front-end pipeline (D0 half-compare register + D order/align register + F2 seed register -- the
    # |x|-vs-|y| compare and the seed barrel-shift are split across these) + the B1 divide-setup register + the
    # QT-product base register (the shared _zkf_pmul's own first stage) + the two post-divide registers (P2 captures the
    # correction operands, B2 does the single unmap add + packer-input assembly -- split so the wide signed unmap add
    # does not chain behind the multiplier) + the output stage. The magnitude product shares the same _zkf_pmul but is
    # issued DURING the divide, so it never adds latency.
    # Then: rotation cycles = ceil(N*100/UNROLL100) (UNROLL100 as in sincos); STEPS = ceil(XF/2) folded radix-4 divider
    # cycles (data-independent: the same divide runs for the bypass and the residual, F = 2*STEPS >= XF quotient bits);
    # STAGE_PRODUCT extra cycles in the shared _zkf_pmul (on the post-divide QT product, the only one on the critical
    # path); the optional STAGE_INPUT register (+1); STAGE_NORMALIZE + STAGE_PACK in the shared _zkf_fixed_to_float
    # back-end; plus the public theta/mag/out_valid STAGE_OUTPUT register. Mirrors zkf_atan2 LATENCY_REF exactly.
    if unroll100 != 50 and (unroll100 < 100 or unroll100 % 100 != 0):
        raise ValueError(f"unroll100 must be 50 or a positive multiple of 100, got {unroll100}")
    spec = TRIG_SPECS[wman]
    n, xf = spec["n_atan2"], spec["xf_atan2"]             # atan2's own iteration count and x/y (divider) width
    iter_cycles = (n * 100 + unroll100 - 1) // unroll100
    steps = (xf + 1) // 2                                  # folded radix-4 divider: 2 quotient bits per cycle
    # The folded radix-4 divider runs one digit per cycle (stock _zkf_div_radix4_step) for STEPS cycles, plus a one-cycle
    # setup that forms 3*den off the registered divisor. Mirrors `ZKF_ATAN2_DIVCYC = STEPS + 1.
    div_cycles = steps + 1
    return (
        8 + iter_cycles + div_cycles + _count(stage_product)
        + _count(stage_input) + _count(stage_normalize)
        + _count(stage_pack) + _count(stage_output)
    )


def module_latency(
    kind: str,
    *,
    wman: int = 0,
    unroll100: int = 100,
    parallel: int = 0,
    stage_input: int = 0,
    stage_reduce: int = 0,
    stage_product: int = 0,
    stage_product_final: int | None = None,
    stage_align: int = 0,
    stage_decode: int = 0,
    stage_normalize: int = 0,
    stage_normalize_output: int = 0,
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
            stage_reduce=stage_reduce,
            stage_product=stage_product,
            stage_pack=stage_pack,
            stage_output=stage_output,
        )
    if kind == "log2":
        return log2_latency(
            wman,
            stage_input=stage_input,
            stage_decode=stage_decode,
            stage_product=stage_product,
            stage_product_final=stage_product_final,
            stage_normalize=stage_normalize,
            stage_normalize_output=stage_normalize_output,
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
    if kind == "atan2":
        return atan2_latency(
            wman,
            unroll100=unroll100,
            stage_input=stage_input,
            stage_product=stage_product,
            stage_normalize=stage_normalize,
            stage_pack=stage_pack,
            stage_output=stage_output,
        )
    raise ValueError(f"unsupported module kind: {kind}")
