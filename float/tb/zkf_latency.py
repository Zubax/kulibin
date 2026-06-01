#!/usr/bin/env python3
"""Latency formulas shared by the ZKF verification suite and synthesis reports.

The cocotb tests use these values as the scoreboard delay, so a wrong value fails
simulation. The synthesis reports import the same helpers so the published latency
is the latency verified by the test suite, not a second copy of the arithmetic.
"""

from __future__ import annotations

from zkf_trans_tables import SPECS as TRANS_SPECS


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
    return 1 + _enabled(stage_input) + _enabled(stage_product) + _enabled(stage_pack) + _enabled(stage_output)


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
        + _enabled(stage_product)
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


def module_latency(
    kind: str,
    *,
    wman: int = 0,
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
    raise ValueError(f"unsupported module kind: {kind}")
