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
import sys

from common import REPO

# The polynomial degree D for zkf_exp2 / zkf_log2 is a closed-form function of WMAN computed by the
# generator; import the emitted table so the synth pipeline-depth metadata stays in lockstep with the RTL.
sys.path.insert(0, str(REPO / "float" / "tb"))
from zkf_trans_tables import SPECS as TRANS_SPECS  # noqa: E402  (path set up immediately above)


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
    stage_input: int = 0     # zkf_div, zkf_from_int, zkf_to_int, zkf_resize, zkf_mul, zkf_fma: 0 or 1.
    stage_product: int = 0   # zkf_mul, zkf_fma: 0 or 1.
    stage_align: int = 0     # zkf_add, zkf_addsub, zkf_fma: 0 or 1 (alignment shifter split).
    stage_decode: int = 0    # zkf_add, zkf_addsub, zkf_mul_ilog2_const, zkf_fma: 0 or 1 (decoded-signal register).
    stage_normalize: int = 0 # zkf_add, zkf_addsub, zkf_fma, zkf_log2, zkf_from_int: 0/1/2 (normshift STAGE_SPLIT).
    stage_pack: int = 0      # zkf_fma, zkf_log2, zkf_exp2, zkf_from_int: 0 or 1 (forwarded to _zkf_pack.STAGE_INPUT).
    stage_output: int = 0    # pack-based ops: 0 = combinational output (default); 1 = registered output (+1 cycle).
    synth_device: str = ""   # flow-interpreted device-size hint ("" = flow default; e.g. "45k" picks a larger ECP5).


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
        name="zkf_mul_w8m36_si1_sp1",
        label="zkf_mul (WEXP=8, WMAN=36, STAGE_INPUT=1 latched inputs + STAGE_PRODUCT=1 split DSP cascade)",
        top="zkf_mul_w8m36_si1_sp1_synth_top",
        kind="mul",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
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
        name="zkf_add_w8m36_sd1_sa1_sn1",
        label="zkf_add (WEXP=8, WMAN=36, FPGA-optimal: STAGE_DECODE=1 register decoded operands, STAGE_ALIGN=1 "
              "split align shifter, STAGE_NORMALIZE=1 split close-cancellation normshift)",
        top="zkf_add_w8m36_sd1_sa1_sn1_synth_top",
        kind="add",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_decode=1,
        stage_align=1,
        stage_normalize=1,
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
        label="zkf_fma (true single-rounding a*b+c; WEXP=6, WMAN=18, STAGE_INPUT=1 latched operands + "
              "STAGE_ALIGN=1 split aligner + STAGE_NORMALIZE=2 FMA-local 3-segment normalizer + STAGE_PACK=1 "
              "registered packer inputs: closes every datapath cone on Yosys and the more pessimistic "
              "Diamond/LSE using a single MULT18X18D.)",
        top="zkf_fma_synth_top",
        kind="fma",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_input=1,
        stage_align=1,
        stage_normalize=2,
        stage_pack=1,
    ),
    ModuleSpec(
        name="zkf_fma_w8m36_sp1_sd1_sa1_sn2_pa1",
        label="zkf_fma (WEXP=8, WMAN=36, STAGE_PRODUCT=1 quad 18x18, STAGE_DECODE=1, STAGE_ALIGN=1, "
              "STAGE_NORMALIZE=2, STAGE_PACK=1: register pack inputs + FMA-local 3-segment normalizer so both "
              "wide cones close)",
        top="zkf_fma_w8m36_sp1_sd1_sa1_sn2_pa1_synth_top",
        kind="fma",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_product=1,
        stage_decode=1,
        stage_align=1,
        stage_normalize=2,
        stage_pack=1,
    ),
    ModuleSpec(
        name="zkf_fma_w8m36_si1_sp1_sd1_sa1_sn2_pa1",
        label="zkf_fma (WEXP=8, WMAN=36, STAGE_INPUT=1 latched inputs + STAGE_PRODUCT=1 quad 18x18, "
              "STAGE_DECODE=1, STAGE_ALIGN=1, STAGE_NORMALIZE=2, STAGE_PACK=1: input register shields the wide "
              "operand bus while the rest closes both wide datapath cones)",
        top="zkf_fma_w8m36_si1_sp1_sd1_sa1_sn2_pa1_synth_top",
        kind="fma",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
        stage_product=1,
        stage_decode=1,
        stage_align=1,
        stage_normalize=2,
        stage_pack=1,
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
        name="zkf_from_int_sn1",
        label="zkf_from_int (WINT=32, STAGE_NORMALIZE=1 split normshift)",
        top="zkf_from_int_sn1_synth_top",
        kind="from_int",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wint=32,
        stage_normalize=1,
    ),
    ModuleSpec(
        name="zkf_from_int_si1_sn1",
        label="zkf_from_int (WINT=32, STAGE_INPUT=1 + STAGE_NORMALIZE=1)",
        top="zkf_from_int_si1_sn1_synth_top",
        kind="from_int",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wint=32,
        stage_input=1,
        stage_normalize=1,
    ),
    ModuleSpec(
        name="zkf_from_int_w8m36_sn1",
        label="zkf_from_int (WEXP=8, WMAN=36, WINT=32, STAGE_NORMALIZE=1 split normshift)",
        top="zkf_from_int_w8m36_sn1_synth_top",
        kind="from_int",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        wint=32,
        stage_normalize=1,
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
    # zkf_exp2 / zkf_log2 (table + polynomial). Both close 100 MHz with margin on the LFE5U-12F at the 6/18
    # reference, but along opposite axes, so their headline entries differ (cf. how zkf_fma's plain entry carries
    # the knobs it needs to close while zkf_div's does not):
    #   - exp2's Horner argument is the full reduced fraction, so acc*w is a wide x wide product. The unsplit form
    #     is fabric-mapped/slow on Diamond/LSE (~88 MHz) and slow on Yosys (~85 MHz), so the headline config carries
    #     STAGE_PRODUCT=1 (each multiply -> a registered 2x2 DSP grid); it then reaches 132 MHz Yosys / 117 Diamond.
    #   - log2's argument is the narrow segment-local fraction, so acc*w is wide x narrow -- a single DSP multiply
    #     both tools map cleanly. It closes unsplit (104 MHz both); STAGE_PRODUCT=1 would split it into the small
    #     asymmetric partials that Diamond fabric-maps (drops it below 100), so log2 is left unsplit and instead
    #     gets STAGE_OUTPUT=1 as its higher-margin variant (107 Yosys / 112 Diamond).
    ModuleSpec(
        name="zkf_exp2",
        label="zkf_exp2 (2**x, table+polynomial; STAGE_PRODUCT=1 splits each Horner multiply into a registered "
              "2x2 DSP grid -- needed to close timing, as the unsplit wide product is fabric-mapped on Diamond/LSE)",
        top="zkf_exp2_synth_top",
        kind="exp2",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_product=1,
    ),
    ModuleSpec(
        name="zkf_log2",
        label="zkf_log2 (log2(x), table+polynomial; STAGE_INPUT=1 shields the decode/evaluator cone + STAGE_NORMALIZE=1 "
              "+ STAGE_PACK=1 keep both wide pre-pack cones below the 100 MHz gate)",
        top="zkf_log2_synth_top",
        kind="log2",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_input=1,
        stage_normalize=1,
        stage_pack=1,
    ),
    ModuleSpec(
        name="zkf_log2_so1",
        label="zkf_log2 (STAGE_NORMALIZE=1 + STAGE_PACK=1 + STAGE_OUTPUT=1 registered output -- higher timing margin)",
        top="zkf_log2_so1_synth_top",
        kind="log2",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_normalize=1,
        stage_pack=1,
        stage_output=1,
    ),
    # WEXP=8, WMAN=36 (degree-4 evaluator: four wide Horner multiplies). The single wide multiply per step (SP=0) and
    # the 2x2 split (SP=1) are both deep DSP cascades that top out near 60 MHz; STAGE_PRODUCT=2 (3x3 split with a
    # registered partial-sum stage) cuts the operands into <=18-bit chunks, so each sub-product packs into a single
    # MULT18X18D output register, and every adder in the sum tree stays shallow. With STAGE_INPUT/STAGE_OUTPUT
    # shielding the wide decode and pack, these need ~36 MULT18X18D, so they target the LFE5U-45F (72 DSP) via
    # synth_device.
    ModuleSpec(
        name="zkf_exp2_w8m36",
        label="zkf_exp2 (WEXP=8, WMAN=36, STAGE_INPUT=1 + STAGE_PRODUCT=2 (3x3 split) + STAGE_OUTPUT=1; LFE5U-45F)",
        top="zkf_exp2_w8m36_synth_top",
        kind="exp2",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
        stage_product=2,
        stage_output=1,
        synth_device="45k",
    ),
    ModuleSpec(
        name="zkf_log2_w8m36",
        label="zkf_log2 (WEXP=8, WMAN=36, STAGE_INPUT=1 + STAGE_PRODUCT=2 (3x3 split) + STAGE_NORMALIZE=2 (deep "
              "normshift split) + STAGE_PACK=1 (register pack inputs) + STAGE_OUTPUT=1; LFE5U-45F)",
        top="zkf_log2_w8m36_synth_top",
        kind="log2",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
        stage_product=2,
        stage_normalize=2,
        stage_pack=1,
        stage_output=1,
        synth_device="45k",
    ),
]


def module_group(spec: ModuleSpec) -> str:
    """Identifier for grouping a module with its STAGE_* variants."""
    match = re.match(r"^(.+?)(?:_(?:si|sp|sa|sd|sn|pa|so)\d+)+$", spec.name)
    return match.group(1) if match else spec.name


def rtl_sources(spec: ModuleSpec) -> list[Path]:
    hdl = REPO / "float" / "hdl"
    if spec.kind == "pack":
        return [hdl / "_zkf_pack.v"]
    if spec.kind == "mul":
        return [hdl / "_zkf_pack.v", hdl / "_zkf_pipe.v", hdl / "zkf_mul.v"]
    if spec.kind == "add":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_pipe.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_add.v",
        ]
    if spec.kind == "addsub":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_pipe.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_add.v",
            hdl / "zkf_addsub.v",
        ]
    if spec.kind == "fma":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_pipe.v",
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
        return [hdl / "_zkf_pipe.v", hdl / "zkf_cmp_comb.v", hdl / "zkf_cmp.v"]
    if spec.kind == "sort":
        return [hdl / "_zkf_pipe.v", hdl / "zkf_cmp_comb.v", hdl / "zkf_sort.v"]
    if spec.kind == "mul_ilog2_const":
        return [hdl / "_zkf_pipe.v", hdl / "zkf_mul_ilog2_const.v"]
    if spec.kind == "from_int":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_pipe.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_fixed_to_float.v",
            hdl / "zkf_from_int.v",
        ]
    if spec.kind == "to_int":
        return [
            hdl / "_zkf_pipe.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "_zkf_to_fixpoint.v",
            hdl / "zkf_to_int.v",
        ]
    if spec.kind == "resize":
        return [
            hdl / "_zkf_pack.v",
            hdl / "_zkf_pipe.v",
            hdl / "zkf_resize.v",
        ]
    if spec.kind in {"exp2", "log2"}:
        # The generate-if selects the table whose name matches WMAN (D = degree(WMAN), from the generated SPECS); the
        # other WMAN branches reference undefined modules but are untaken, so synthesis prunes them (like the
        # _zkf_invalid_* sentinels). Yosys's hierarchy -check, however, also elaborates the *generic* zkf_<func>
        # (default WMAN), so that WMAN's table must be present too -- include both (deduped) and let synthesis prune
        # the unused generic.
        def table(wman: int) -> Path:
            return hdl / "_tables" / f"_zkf_{spec.kind}_m{wman}_d{TRANS_SPECS[(spec.kind, wman)]['d']}.v"
        DEFAULT_WMAN = 18  # the default WMAN of zkf_exp2 / zkf_log2
        tables = [table(w) for w in sorted({DEFAULT_WMAN, spec.wman})]
        sources = [hdl / "_zkf_pack.v", hdl / "_zkf_pipe.v"]
        if spec.kind == "exp2":
            # exp2's _zkf_to_fixpoint helper uses _zkf_rshift_sticky for the right-shift path; the helper itself
            # owns the decode + folded-constant predicate cone shared with zkf_to_int.
            sources += [hdl / "_zkf_rshift_sticky.v", hdl / "_zkf_to_fixpoint.v"]
        if spec.kind == "log2":
            # log2's _zkf_fixed_to_float helper owns the _zkf_normshift instance (STAGE_SPLIT = 1 + STAGE_NORMALIZE)
            # plus the normshift -> pack-input combine -> _zkf_pack pipeline shared with zkf_from_int.
            sources += [hdl / "_zkf_normshift.v", hdl / "_zkf_fixed_to_float.v", hdl / "_zkf_log2_final_mul.v"]
        return sources + [hdl / "_zkf_horner.v", *tables, hdl / f"zkf_{spec.kind}.v"]
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
        # 1 (product) + STAGE_INPUT (latched inputs) + STAGE_PRODUCT (DSP cascade split) + STAGE_PACK (pack input
        # register) + STAGE_OUTPUT (pack output).
        return (1 + spec.stage_input + spec.stage_output + spec.stage_pack
                + (1 if spec.stage_product >= 1 else 0))
    if spec.kind in {"add", "addsub"}:
        # 4 base + STAGE_INPUT + STAGE_DECODE + STAGE_ALIGN + STAGE_NORMALIZE + STAGE_PACK + STAGE_OUTPUT.
        # STAGE_NORMALIZE adds 1 cycle per unit symmetrically to both sub-path (normshift internal) and add-path
        # (s2x catch-up).
        return (4 + spec.stage_input + spec.stage_output + spec.stage_decode + spec.stage_align
                + spec.stage_normalize + spec.stage_pack)
    if spec.kind == "fma":
        # 5 base (product, order, align-capture, add, normalize+pack) + STAGE_INPUT (latched inputs)
        # + STAGE_PRODUCT (DSP split) + STAGE_DECODE (decode/compare split) + STAGE_ALIGN (align split)
        # + STAGE_NORMALIZE (sub-path normshift internal + add-path s2x catch-up) + STAGE_PACK (pack-input
        # register) + STAGE_OUTPUT (pack output register).
        return (5 + spec.stage_input + (1 if spec.stage_product >= 1 else 0)
                + spec.stage_decode + spec.stage_align + spec.stage_normalize
                + spec.stage_pack + spec.stage_output)
    if spec.kind == "div_core":
        return div_core_stages
    if spec.kind == "div":
        return div_core_stages + spec.stage_output + spec.stage_input + spec.stage_pack
    if spec.kind in {"cmp", "sort"}:
        return 1 + spec.stage_input
    if spec.kind == "mul_ilog2_const":
        return 1 + spec.stage_input + spec.stage_decode
    if spec.kind == "from_int":
        # 1 (S1 register) + STAGE_INPUT + STAGE_NORMALIZE + STAGE_PACK + STAGE_OUTPUT.
        return (1 + spec.stage_input + spec.stage_normalize + spec.stage_pack + spec.stage_output)
    if spec.kind == "to_int":
        return 4 + spec.stage_input          # does not use _zkf_pack; unaffected by the packer pipeline
    if spec.kind == "resize":
        # Both the widen-only fast path and the _zkf_pack path honor STAGE_OUTPUT; STAGE_INPUT adds the input pipe.
        return spec.stage_output + spec.stage_input
    if spec.kind in {"exp2", "log2"}:
        # Closed-form depth: STAGE_INPUT + front + D*(2 + STAGE_PRODUCT) + extras + STAGE_PACK + STAGE_OUTPUT.
        # Front stages: exp2 has 3 reduction + 2 ROM-read = 5; log2 has 1 P1 + 2 ROM-read + 2 final-mul base
        # (registered inputs + outputs, see _zkf_log2_final_mul) = 5.
        # log2 extras: STAGE_PRODUCT (t*P split) + STAGE_NORMALIZE (normshift internal barriers).
        degree = TRANS_SPECS[(spec.kind, spec.wman)]["d"]
        front = 5
        log2_extra = (spec.stage_product + spec.stage_normalize) if spec.kind == "log2" else 0
        return (spec.stage_input + front + log2_extra + degree * (2 + spec.stage_product)
                + spec.stage_pack + spec.stage_output)
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


def _sn_suffix(spec: ModuleSpec) -> str:
    return f", STAGE_NORMALIZE={spec.stage_normalize}" if spec.stage_normalize else ""


def _pa_suffix(spec: ModuleSpec) -> str:
    return f", STAGE_PACK={spec.stage_pack}" if spec.stage_pack else ""


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
            f"QFRAC={div_qfrac(spec)}, WEXP_UNBIASED={spec.wexp + 2}"
            f"{_si_suffix(spec)}{_pa_suffix(spec)}{_so_suffix(spec)}"
        )
    if spec.kind == "mul_ilog2_const":
        return f"WEXP={spec.wexp}, WMAN={spec.wman}, K={MUL_ILOG2_CONST_K}{_si_suffix(spec)}{_sd_suffix(spec)}"
    if spec.kind == "to_int":
        return f"WEXP={spec.wexp}, WMAN={spec.wman}, WINT={spec.wint}{_si_suffix(spec)}"
    if spec.kind == "resize":
        return (
            f"WEXP_IN={spec.wexp_in}, WMAN_IN={spec.wman_in}, "
            f"WEXP_OUT={spec.wexp_out}, WMAN_OUT={spec.wman_out}{_si_suffix(spec)}"
        )
    if spec.kind in {"cmp", "sort"}:
        return f"WEXP={spec.wexp}, WMAN={spec.wman}{_si_suffix(spec)}"
    if spec.kind == "mul":
        return (f"WEXP={spec.wexp}, WMAN={spec.wman}"
                f"{_sp_suffix(spec)}{_si_suffix(spec)}{_pa_suffix(spec)}{_so_suffix(spec)}")
    if spec.kind in {"add", "addsub"}:
        return (f"WEXP={spec.wexp}, WMAN={spec.wman}"
                f"{_si_suffix(spec)}{_sd_suffix(spec)}{_sa_suffix(spec)}{_sn_suffix(spec)}"
                f"{_pa_suffix(spec)}{_so_suffix(spec)}")
    if spec.kind == "from_int":
        return (f"WEXP={spec.wexp}, WMAN={spec.wman}, WINT={spec.wint}"
                f"{_si_suffix(spec)}{_sn_suffix(spec)}{_pa_suffix(spec)}")
    if spec.kind in {"exp2", "log2"}:
        return (f"WEXP={spec.wexp}, WMAN={spec.wman}"
                f"{_sp_suffix(spec)}{_sn_suffix(spec)}{_pa_suffix(spec)}{_so_suffix(spec)}")
    if spec.kind == "fma":
        return (f"WEXP={spec.wexp}, WMAN={spec.wman}"
                f"{_sp_suffix(spec)}{_si_suffix(spec)}{_sd_suffix(spec)}{_sa_suffix(spec)}"
                f"{_sn_suffix(spec)}{_pa_suffix(spec)}{_so_suffix(spec)}")
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
