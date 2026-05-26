"""Float synthesis module catalog: the device-independent set of cores to evaluate.

Defines what gets synthesized (ModuleSpec + MODULES), the RTL source list per kind, and the derived
metadata shown in the reports (parameters, pipeline depth, variant grouping). No flow/tool specifics
live here; both the Yosys and Diamond entry points import from this module. Not runnable on its own.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import re

from common import REPO


@dataclass(frozen=True)
class ModuleSpec:
    name: str
    label: str
    top: str
    kind: str
    wexp: int
    wman: int
    wexp_unbiased: int
    wint: int = 0
    wexp_in: int = 0
    wman_in: int = 0
    wexp_out: int = 0
    wman_out: int = 0
    stage_input: int = 0     # zkf_div, zkf_from_int, zkf_to_int, zkf_resize: 0 or 1.
    stage_product: int = 0   # zkf_mul: 0 or 1.
    stage_align: int = 0     # zkf_add, zkf_addsub, zkf_fma: 0 or 1 (alignment shifter split).
    stage_decode: int = 0    # zkf_add, zkf_addsub, zkf_mul_ilog2_const: 0 or 1 (decoded-signal register).
    stage_output: int = 0    # pack-based ops: 0 = combinational output (default); 1 = registered output (+1 cycle).


MUL_ILOG2_CONST_K = 10  # representative midrange shift for the synthesis evaluation harness


MODULES = [
    ModuleSpec(
        name="_zkf_pack",
        label="_zkf_pack (normalized GRS)",
        top="_zkf_pack_synth_top",
        kind="pack",
        wexp=6,
        wman=18,
        wexp_unbiased=8,
    ),
    ModuleSpec(
        name="zkf_mul",
        label="zkf_mul",
        top="zkf_mul_synth_top",
        kind="mul",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_mul_sp1",
        label="zkf_mul (STAGE_PRODUCT=1)",
        top="zkf_mul_sp1_synth_top",
        kind="mul",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_product=1,
    ),
    ModuleSpec(
        name="zkf_mul_so1",
        label="zkf_mul (STAGE_OUTPUT=1, registered output)",
        top="zkf_mul_so1_synth_top",
        kind="mul",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_output=1,
    ),
    ModuleSpec(
        name="zkf_mul_w8m36_so1",
        label="zkf_mul (WEXP=8, WMAN=36, STAGE_PRODUCT=1, STAGE_OUTPUT=1)",
        top="zkf_mul_w8m36_so1_synth_top",
        kind="mul",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_product=1,
        stage_output=1,
    ),
    ModuleSpec(
        name="zkf_mul_w8m36_sp1",
        label="zkf_mul (WEXP=8, WMAN=36, STAGE_PRODUCT=1 split DSP cascade)",
        top="zkf_mul_w8m36_sp1_synth_top",
        kind="mul",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_product=1,
    ),
    ModuleSpec(
        name="zkf_mul_w8m25_sp1",
        label="zkf_mul (WEXP=8, WMAN=25, STAGE_PRODUCT=1 asymmetric split WLO=13/WHI=12)",
        top="zkf_mul_w8m25_sp1_synth_top",
        kind="mul",
        wexp=8,
        wman=25,
        wexp_unbiased=0,
        stage_product=1,
    ),
    ModuleSpec(
        name="zkf_add",
        label="zkf_add",
        top="zkf_add_synth_top",
        kind="add",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_add_w8m36_sd1_sa1",
        label="zkf_add (WEXP=8, WMAN=36, FPGA-optimal: quad 18x18, STAGE_DECODE=1 register decoded operands, "
              "STAGE_ALIGN=1 split align shifter)",
        top="zkf_add_w8m36_sd1_sa1_synth_top",
        kind="add",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_decode=1,
        stage_align=1,
    ),
    ModuleSpec(
        name="zkf_addsub",
        label="zkf_addsub",
        top="zkf_addsub_synth_top",
        kind="addsub",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_fma",
        label="zkf_fma (true single-rounding a*b+c)",
        top="zkf_fma_synth_top",
        kind="fma",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="_zkf_div_core",
        label="_zkf_div_core",
        top="_zkf_div_core_synth_top",
        kind="div_core",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_div",
        label="zkf_div",
        top="zkf_div_synth_top",
        kind="div",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_div_si1",
        label="zkf_div (STAGE_INPUT=1)",
        top="zkf_div_si1_synth_top",
        kind="div",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_input=1,
    ),
    ModuleSpec(
        name="zkf_div_w8m36",
        label="zkf_div (WEXP=8, WMAN=36, FPGA-optimal: quad 18x18; STAGE_INPUT=1 shields the wide input decode cone, "
              "STAGE_OUTPUT=1 registers the wide quotient round so Diamond/LSE closes timing)",
        top="zkf_div_w8m36_synth_top",
        kind="div",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
        stage_output=1,
    ),
    ModuleSpec(
        name="zkf_cmp",
        label="zkf_cmp",
        top="zkf_cmp_synth_top",
        kind="cmp",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_cmp_w8m36",
        label="zkf_cmp (WEXP=8, WMAN=36)",
        top="zkf_cmp_w8m36_synth_top",
        kind="cmp",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_sort",
        label="zkf_sort",
        top="zkf_sort_synth_top",
        kind="sort",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_sort_w8m36",
        label="zkf_sort (WEXP=8, WMAN=36)",
        top="zkf_sort_w8m36_synth_top",
        kind="sort",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_mul_ilog2_const",
        label="zkf_mul_ilog2_const (K=+10)",
        top="zkf_mul_ilog2_const_synth_top",
        kind="mul_ilog2_const",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_mul_ilog2_const_w8m36_sd1",
        label="zkf_mul_ilog2_const (WEXP=8, WMAN=36, K=+10, STAGE_DECODE=1)",
        top="zkf_mul_ilog2_const_w8m36_sd1_synth_top",
        kind="mul_ilog2_const",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_decode=1,
    ),
    ModuleSpec(
        name="zkf_from_int",
        label="zkf_from_int (WINT=32)",
        top="zkf_from_int_synth_top",
        kind="from_int",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wint=32,
    ),
    ModuleSpec(
        name="zkf_from_int_si1",
        label="zkf_from_int (WINT=32, STAGE_INPUT=1)",
        top="zkf_from_int_si1_synth_top",
        kind="from_int",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wint=32,
        stage_input=1,
    ),
    ModuleSpec(
        name="zkf_from_int_w8m36",
        label="zkf_from_int (WEXP=8, WMAN=36, WINT=32)",
        top="zkf_from_int_w8m36_synth_top",
        kind="from_int",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        wint=32,
    ),
    ModuleSpec(
        name="zkf_to_int",
        label="zkf_to_int (WINT=32)",
        top="zkf_to_int_synth_top",
        kind="to_int",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wint=32,
    ),
    ModuleSpec(
        name="zkf_to_int_si1",
        label="zkf_to_int (WINT=32, STAGE_INPUT=1)",
        top="zkf_to_int_si1_synth_top",
        kind="to_int",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wint=32,
        stage_input=1,
    ),
    ModuleSpec(
        name="zkf_to_int_w8m36",
        label="zkf_to_int (WEXP=8, WMAN=36, WINT=32)",
        top="zkf_to_int_w8m36_synth_top",
        kind="to_int",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        wint=32,
    ),
    ModuleSpec(
        name="zkf_resize_narrow",
        label="zkf_resize 6/18 -> 5/11 (narrowing)",
        top="zkf_resize_narrow_synth_top",
        kind="resize",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wexp_in=6,
        wman_in=18,
        wexp_out=5,
        wman_out=11,
    ),
    ModuleSpec(
        name="zkf_resize_narrow_si1",
        label="zkf_resize 6/18 -> 5/11 (narrowing, STAGE_INPUT=1)",
        top="zkf_resize_narrow_si1_synth_top",
        kind="resize",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wexp_in=6,
        wman_in=18,
        wexp_out=5,
        wman_out=11,
        stage_input=1,
    ),
    ModuleSpec(
        name="zkf_resize_widen",
        label="zkf_resize 5/11 -> 6/18 (widening)",
        top="zkf_resize_widen_synth_top",
        kind="resize",
        wexp=5,
        wman=11,
        wexp_unbiased=0,
        wexp_in=5,
        wman_in=11,
        wexp_out=6,
        wman_out=18,
    ),
    ModuleSpec(
        name="zkf_resize_widen_si1",
        label="zkf_resize 5/11 -> 6/18 (widening, STAGE_INPUT=1)",
        top="zkf_resize_widen_si1_synth_top",
        kind="resize",
        wexp=5,
        wman=11,
        wexp_unbiased=0,
        wexp_in=5,
        wman_in=11,
        wexp_out=6,
        wman_out=18,
        stage_input=1,
    ),
    ModuleSpec(
        name="zkf_resize_narrow_w8m36",
        label="zkf_resize 8/36 -> 6/18 (narrowing)",
        top="zkf_resize_narrow_w8m36_synth_top",
        kind="resize",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        wexp_in=8,
        wman_in=36,
        wexp_out=6,
        wman_out=18,
    ),
    ModuleSpec(
        name="zkf_resize_widen_w8m36",
        label="zkf_resize 6/18 -> 8/36 (widening)",
        top="zkf_resize_widen_w8m36_synth_top",
        kind="resize",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wexp_in=6,
        wman_in=18,
        wexp_out=8,
        wman_out=36,
    ),
]


def module_group(spec: ModuleSpec) -> str:
    """Identifier for grouping a module with its STAGE_* variants."""
    match = re.match(r"^(.+?)(?:_(?:si|sp|sa|sd)\d+)+$", spec.name)
    return match.group(1) if match else spec.name


def rtl_sources(spec: ModuleSpec) -> list[Path]:
    hdl = REPO / "float" / "hdl"
    if spec.kind == "pack":
        return [hdl / "_zkf_pack.v"]
    if spec.kind == "mul":
        return [hdl / "_zkf_pack.v", hdl / "zkf_mul.v"]
    if spec.kind == "add":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_add.v",
        ]
    if spec.kind == "addsub":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_add.v",
            hdl / "zkf_addsub.v",
        ]
    if spec.kind == "fma":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_fma.v",
        ]
    if spec.kind == "div_core":
        return [hdl / "_zkf_div_core.v"]
    if spec.kind == "div":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_pipe.v",
            hdl / "_zkf_div_core.v",
            hdl / "zkf_div.v",
        ]
    if spec.kind == "cmp":
        return [hdl / "zkf_cmp_comb.v", hdl / "zkf_cmp.v"]
    if spec.kind == "sort":
        return [hdl / "zkf_cmp_comb.v", hdl / "zkf_sort.v"]
    if spec.kind == "mul_ilog2_const":
        return [hdl / "zkf_mul_ilog2_const.v"]
    if spec.kind == "from_int":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_pipe.v",
            hdl / "_zkf_normshift.v",
            hdl / "zkf_from_int.v",
        ]
    if spec.kind == "to_int":
        return [
            hdl / "_zkf_pipe.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_to_int.v",
        ]
    if spec.kind == "resize":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_pipe.v",
            hdl / "zkf_resize.v",
        ]
    raise ValueError(f"unsupported module kind: {spec.kind}")


def div_qfrac(spec: ModuleSpec) -> int:
    qfrac_base = spec.wman + 2
    return qfrac_base + (qfrac_base % 2)


def register_stages(spec: ModuleSpec) -> int:
    qfrac_base = spec.wman + 2
    qfrac = qfrac_base + (qfrac_base % 2)
    div_core_stages = 2 + (qfrac // 2)

    # Every pack-based op ends in _zkf_pack, whose output stage is STAGE_OUTPUT (0 = combinational, 1 = registered).
    if spec.kind == "pack":
        return spec.stage_output
    if spec.kind == "mul":
        # 1 (product) + STAGE_OUTPUT (pack output) + STAGE_PRODUCT (DSP cascade split). Default 1 + STAGE_PRODUCT.
        return 1 + spec.stage_output + (1 if spec.stage_product >= 1 else 0)
    if spec.kind in {"add", "addsub"}:
        return 4 + spec.stage_output + spec.stage_decode + spec.stage_align
    if spec.kind == "fma":
        # 5 base (product, order, align-capture, add, normalize+pack) + STAGE_PRODUCT (DSP split)
        # + STAGE_ALIGN (alignment shifter split) + STAGE_OUTPUT (pack output register).
        return 5 + (1 if spec.stage_product >= 1 else 0) + spec.stage_align + spec.stage_output
    if spec.kind == "div_core":
        return div_core_stages
    if spec.kind == "div":
        return div_core_stages + spec.stage_output + spec.stage_input
    if spec.kind in {"cmp", "sort"}:
        return 1
    if spec.kind == "mul_ilog2_const":
        return 1 + spec.stage_decode
    if spec.kind == "from_int":
        return 2 + spec.stage_output + spec.stage_input   # 2 front stages + STAGE_OUTPUT pack output
    if spec.kind == "to_int":
        return 4 + spec.stage_input          # does not use _zkf_pack; unaffected by the packer pipeline
    if spec.kind == "resize":
        # Both the widen-only fast path and the _zkf_pack path honor STAGE_OUTPUT; STAGE_INPUT adds the input pipe.
        return spec.stage_output + spec.stage_input
    raise ValueError(f"unsupported module kind: {spec.kind}")


def format_register_stages(stages: int) -> str:
    suffix = "stage" if stages == 1 else "stages"
    return f"{stages} {suffix}"


def _si_suffix(spec: ModuleSpec) -> str:
    return f", STAGE_INPUT={spec.stage_input}" if spec.stage_input else ""


def _sp_suffix(spec: ModuleSpec) -> str:
    return f", STAGE_PRODUCT={spec.stage_product}" if spec.stage_product else ""


def _so_suffix(spec: ModuleSpec) -> str:
    return ", STAGE_OUTPUT=1" if spec.stage_output == 1 else ""


def _sa_suffix(spec: ModuleSpec) -> str:
    return f", STAGE_ALIGN={spec.stage_align}" if spec.stage_align else ""


def _sd_suffix(spec: ModuleSpec) -> str:
    return f", STAGE_DECODE={spec.stage_decode}" if spec.stage_decode else ""


def params(spec: ModuleSpec) -> str:
    if spec.kind == "pack":
        return f"WEXP={spec.wexp}, WMAN={spec.wman}, WEXP_UNBIASED={spec.wexp_unbiased}"
    if spec.kind == "div_core":
        return (
            f"WEXP={spec.wexp}, WMAN={spec.wman}, "
            f"QFRAC={div_qfrac(spec)}, WEXP_UNBIASED={spec.wexp + 2}"
        )
    if spec.kind == "div":
        return (
            f"WEXP={spec.wexp}, WMAN={spec.wman}, "
            f"QFRAC={div_qfrac(spec)}, WEXP_UNBIASED={spec.wexp + 2}{_si_suffix(spec)}"
        )
    if spec.kind == "mul_ilog2_const":
        return f"WEXP={spec.wexp}, WMAN={spec.wman}, K={MUL_ILOG2_CONST_K}{_sd_suffix(spec)}"
    if spec.kind in {"from_int", "to_int"}:
        return f"WEXP={spec.wexp}, WMAN={spec.wman}, WINT={spec.wint}{_si_suffix(spec)}"
    if spec.kind == "resize":
        return (
            f"WEXP_IN={spec.wexp_in}, WMAN_IN={spec.wman_in}, "
            f"WEXP_OUT={spec.wexp_out}, WMAN_OUT={spec.wman_out}{_si_suffix(spec)}"
        )
    if spec.kind in {"cmp", "sort"}:
        return f"WEXP={spec.wexp}, WMAN={spec.wman}"
    if spec.kind == "mul":
        return f"WEXP={spec.wexp}, WMAN={spec.wman}{_sp_suffix(spec)}{_so_suffix(spec)}"
    if spec.kind in {"add", "addsub"}:
        return f"WEXP={spec.wexp}, WMAN={spec.wman}{_sd_suffix(spec)}{_sa_suffix(spec)}"
    if spec.kind == "fma":
        return f"WEXP={spec.wexp}, WMAN={spec.wman}{_sp_suffix(spec)}{_sa_suffix(spec)}{_so_suffix(spec)}"
    return f"WEXP={spec.wexp}, WMAN={spec.wman}"


def selected_modules(names: str | None) -> list[ModuleSpec]:
    if not names:
        return MODULES
    selected = {name.strip() for name in names.split(",") if name.strip()}
    modules = [spec for spec in MODULES if spec.name in selected]
    missing = selected - {spec.name for spec in modules}
    if missing:
        raise ValueError(f"unknown module names: {', '.join(sorted(missing))}")
    return modules


def flow_modules(args_modules: str | None, flow_env_name: str) -> list[ModuleSpec]:
    names = (
        args_modules
        or os.environ.get(flow_env_name)
        or os.environ.get("FLOAT_SYNTH_MODULES")
        or os.environ.get("SYNTH_MODULES")
    )
    return selected_modules(names)
