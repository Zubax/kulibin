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

# Latency is owned by the verification suite; importing it here keeps the HTML reports in lockstep with the
# scoreboard delays used by the cocotb tests.
sys.path.insert(0, str(REPO / "float" / "tb"))
from zkf_latency import div_qfrac as latency_div_qfrac, module_latency  # noqa: E402  (path set up immediately above)


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
    stage_product: int = 0   # zkf_mul/fma/exp2/log2/sincos: _zkf_pmul pipeline depth / split 0..4.
    stage_align: int = 0     # zkf_add, zkf_addsub, zkf_fma: 0 or 1 (alignment shifter split).
    stage_decode: int = 0    # zkf_add, zkf_addsub, zkf_mul_ilog2_const, zkf_fma: 0 or 1 (decoded-signal register).
    stage_normalize: int = 0 # zkf_add, zkf_addsub, zkf_fma, zkf_log2, zkf_from_int: 0/1/2 (normshift STAGE_SPLIT).
    stage_pack: int = 0      # zkf_fma, zkf_log2, zkf_exp2, zkf_from_int: 0 or 1 (forwarded to _zkf_pack.STAGE_INPUT).
    stage_output: int = 0    # pack-based ops: 0 = combinational output (default); 1 = registered output (+1 cycle).
    unroll100: int = 100     # zkf_sincos: CORDIC iterations per engine cycle x100 (50 = half-rate; 100/200/300/400).
    parallel: int = -1       # zkf_sincos: run z ahead of x/y. -1 = auto (the RTL default, = UNROLL100 < 100); 0/1 force.
    wmultiplier: int = 0     # zkf_mul/fma/exp2/log2/sincos: _zkf_pmul DSP tile-width hint (0 = symmetric; >=8 -> slice grid).
    synth_device: str = ""   # flow-interpreted device-size hint ("" = flow default; e.g. "45k" picks a larger ECP5).
    emit_schematic: bool = True  # wide flattened generic schematics can dominate runtime; timing does not need them.


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
        label="zkf_mul (WEXP=8, WMAN=36, STAGE_PRODUCT=2 registered 2x2 18x18 split, STAGE_PACK=1, STAGE_OUTPUT=1)",
        top="zkf_mul_w8m36_so1_synth_top",
        kind="mul",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_product=2,
        wmultiplier=18,
        stage_pack=1,
        stage_output=1,
    ),
    ModuleSpec(
        name="zkf_mul_w8m36_sp2",
        label="zkf_mul (WEXP=8, WMAN=36, STAGE_PRODUCT=2 registered 2x2 18x18 split, WMULTIPLIER=18, STAGE_PACK=1 "
              "registers the pack inputs so the product->round->pack route closes on the more pessimistic Diamond/LSE)",
        top="zkf_mul_w8m36_sp2_synth_top",
        kind="mul",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_product=2,
        wmultiplier=18,
        stage_pack=1,
    ),
    ModuleSpec(
        name="zkf_mul_w8m36_si1_sp2",
        label="zkf_mul (WEXP=8, WMAN=36, STAGE_INPUT=1 latched inputs + STAGE_PRODUCT=2 registered 2x2 18x18 "
              "split, WMULTIPLIER=18, STAGE_PACK=1 registers pack inputs for Diamond/LSE closure)",
        top="zkf_mul_w8m36_si1_sp2_synth_top",
        kind="mul",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
        stage_product=2,
        wmultiplier=18,
        stage_pack=1,
    ),
    ModuleSpec(
        name="zkf_mul_w8m25_sp2",
        label="zkf_mul (WEXP=8, WMAN=25, STAGE_PRODUCT=2 registered symmetric 2x2 split 13/12, STAGE_PACK=1 "
              "registers pack inputs for Diamond/LSE closure)",
        top="zkf_mul_w8m25_sp2_synth_top",
        kind="mul",
        wexp=8,
        wman=25,
        wexp_unbiased=0,
        stage_product=2,
        stage_pack=1,
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
              "STAGE_DECODE=1 splits the post-product normalize + magnitude-compare/select cone + STAGE_ALIGN=1 "
              "split aligner + STAGE_NORMALIZE=2 FMA-local 3-segment normalizer + STAGE_PACK=1 registered packer "
              "inputs: closes every datapath cone on Yosys and the more pessimistic Diamond/LSE using a single "
              "MULT18X18D.)",
        top="zkf_fma_synth_top",
        kind="fma",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_input=1,
        stage_decode=1,
        stage_align=1,
        stage_normalize=2,
        stage_pack=1,
    ),
    ModuleSpec(
        name="zkf_fma_w8m36_sp2_sd1_sa1_sn2_pa1",
        label="zkf_fma (WEXP=8, WMAN=36, STAGE_PRODUCT=2 registered 2x2 quad 18x18, WMULTIPLIER=18, STAGE_DECODE=1, "
              "STAGE_ALIGN=1, STAGE_NORMALIZE=2, STAGE_PACK=1: register pack inputs + FMA-local 3-segment normalizer "
              "so both wide cones close)",
        top="zkf_fma_w8m36_sp2_sd1_sa1_sn2_pa1_synth_top",
        kind="fma",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_product=2,
        wmultiplier=18,
        stage_decode=1,
        stage_align=1,
        stage_normalize=2,
        stage_pack=1,
    ),
    ModuleSpec(
        name="zkf_fma_w8m36_si1_sp2_sd1_sa1_sn2_pa1",
        label="zkf_fma (WEXP=8, WMAN=36, STAGE_INPUT=1 latched inputs + STAGE_PRODUCT=2 registered 2x2 quad 18x18, "
              "WMULTIPLIER=18, STAGE_DECODE=1, STAGE_ALIGN=1, STAGE_NORMALIZE=2, STAGE_PACK=1: input register shields "
              "the wide operand bus while the rest closes both wide datapath cones)",
        top="zkf_fma_w8m36_si1_sp2_sd1_sa1_sn2_pa1_synth_top",
        kind="fma",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
        stage_product=2,
        wmultiplier=18,
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
        emit_schematic=False,
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
    # zkf_round (round-to-integer-valued float; runtime round_mode). The rounder is a variable-position
    # boundary-mask + guard/sticky reduction + increment adder feeding _zkf_pack as a pre-biased assembler
    # (EXP_IS_BIASED=1, no bias round-trip). Unpipelined the cone is ~21 ns, so the headline configs carry
    # STAGE_DECODE=1 (split mask generation from the reduction/add) and STAGE_PACK=1 (register the rounder->packer
    # cut). At 8/36 the wider 36-bit reduction also needs STAGE_OUTPUT=1 to hold 100 MHz on the Spartan/nextpnr flow.
    ModuleSpec(
        name="zkf_round",
        label="zkf_round (WEXP=6, WMAN=18, STAGE_DECODE=1 + STAGE_PACK=1)",
        top="zkf_round_synth_top",
        kind="round",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_decode=1,
        stage_pack=1,
    ),
    ModuleSpec(
        name="zkf_round_w8m36",
        label="zkf_round (WEXP=8, WMAN=36, STAGE_DECODE=1 + STAGE_PACK=1 + STAGE_OUTPUT=1)",
        top="zkf_round_w8m36_synth_top",
        kind="round",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_decode=1,
        stage_pack=1,
        stage_output=1,
    ),
    # zkf_exp2 / zkf_log2 (table + polynomial). Both close 100 MHz with margin on the LFE5U-12F at the 6/18
    # reference, but along opposite axes, so their headline entries differ (cf. how zkf_fma's plain entry carries
    # the knobs it needs to close while zkf_div's does not):
    #   - exp2's Horner argument is the full reduced fraction, so acc*w is a wide x wide product (35x10 at WMAN=18).
    #     The unsplit/native forms (STAGE_PRODUCT 0/1) leave the multi-DSP cascade's output sum unregistered and top
    #     out ~85 MHz on Yosys, so the headline carries STAGE_PRODUCT=2: each Horner multiply maps to a registered
    #     2x2 DSP grid with an operand-capture stage (in the shared _zkf_pmul the registered split starts at 2, since
    #     1 is operand-capture + native multiply). It then reaches ~125 MHz Yosys.
    #   - log2's argument is the narrow segment-local fraction, so acc*w is wide x narrow -- a single DSP multiply
    #     both tools map cleanly, so the product is left unsplit (STAGE_PRODUCT=0). The shared multiplier's wider
    #     product register, however, shifts the close-cancellation normalizer onto the critical path, so the headline
    #     carries STAGE_NORMALIZE=2 to split it (~108 MHz Yosys); log2_so1 (STAGE_OUTPUT=1) is the higher-margin variant.
    ModuleSpec(
        name="zkf_exp2",
        label="zkf_exp2 (2**x, table+polynomial; STAGE_PRODUCT=2 splits each Horner multiply into a registered "
              "2x2 DSP grid with an operand-capture stage -- needed to close timing on ECP5, as the capture+native "
              "product (STAGE_PRODUCT=1) leaves the DSP-output sum unregistered)",
        top="zkf_exp2_synth_top",
        kind="exp2",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_product=2,
    ),
    ModuleSpec(
        name="zkf_log2",
        label="zkf_log2 (log2(x), table+polynomial; STAGE_INPUT=1 shields the decode/evaluator cone + STAGE_NORMALIZE=2 "
              "splits the close-cancellation normshift + STAGE_PACK=1 keep both wide pre-pack cones below the 100 MHz gate)",
        top="zkf_log2_synth_top",
        kind="log2",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        stage_input=1,
        stage_normalize=2,
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
    # WEXP=8, WMAN=36 (degree-4 evaluator: four wide Horner multiplies). The shallow product modes are deep DSP
    # cascades that top out near 60 MHz; the split product modes cut the operands into chunks and add the
    # operand-capture stage. WMULTIPLIER=18 pins each slice to an 18-bit DSP tile: a symmetric STAGE_PRODUCT=3 split
    # (WMULTIPLIER=0) would cut the 53-bit accumulator into 18/18/17-bit slices, but the signed slice product then
    # needs a 19-bit operand (18 magnitude + sign), one bit past the MULT18X18 limit, so Lattice LSE drops the whole
    # Horner multiply into a fabric carry-chain soft multiplier (~76 MHz). The 18-bit tile hint derives a 4x3 (signed)
    # / 2x3 (unsigned final mul) grid whose slices fit one tile each, so every multiply maps to DSP on both Yosys and
    # Diamond/LSE; latency is unchanged. exp2 closes at STAGE_PRODUCT=3 (single-stage GA-way column sum); log2's larger
    # design (the extra final t*P multiply + the wide normshift back-end) places its Horner reduction worse, so its
    # single-stage GA=4 column sum is the Diamond/LSE limiter (~77 MHz, insensitive to retiming and PAR effort). log2
    # therefore uses STAGE_PRODUCT=4, which keeps the same DSP grid but splits that final column sum into a registered
    # pairwise reduction (105+ MHz). These need <=48 MULT18X18D, so they target the LFE5U-45F (72 DSP) via synth_device.
    ModuleSpec(
        name="zkf_exp2_w8m36",
        label="zkf_exp2 (WEXP=8, WMAN=36, STAGE_INPUT=1 + STAGE_PRODUCT=3 + WMULTIPLIER=18 18-bit DSP-tile grid + "
              "STAGE_OUTPUT=1; LFE5U-45F)",
        top="zkf_exp2_w8m36_synth_top",
        kind="exp2",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
        stage_product=3,
        wmultiplier=18,
        stage_output=1,
        synth_device="45k",
        emit_schematic=False,
    ),
    ModuleSpec(
        name="zkf_log2_w8m36",
        label="zkf_log2 (WEXP=8, WMAN=36, STAGE_INPUT=1 + STAGE_PRODUCT=4 (3x3 grid + two-stage reduction) + "
              "WMULTIPLIER=18 18-bit DSP-tile grid + STAGE_NORMALIZE=2 (deep normshift split) + STAGE_PACK=1 "
              "(register pack inputs) + STAGE_OUTPUT=1; LFE5U-45F)",
        top="zkf_log2_w8m36_synth_top",
        kind="log2",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        stage_input=1,
        stage_product=4,
        wmultiplier=18,
        stage_normalize=2,
        stage_pack=1,
        stage_output=1,
        synth_device="45k",
        emit_schematic=False,
    ),
    # sin/cos of a phase in turns: a turns-reduction front end, an iterative folded CORDIC (one datapath reused), the
    # tiny-input bypass multiply, and two _zkf_fixed_to_float back ends. The rotation array is pure logic; the only DSPs
    # are the shared 2*pi linear-correction multiply. STAGE_DECODE=1 splits the input exponent-decode cone and
    # STAGE_NORMALIZE=2 + STAGE_PACK=1 keep the two pre-pack cones under the 100 MHz gate across PNR seeds.
    ModuleSpec(
        name="zkf_sincos",
        label="zkf_sincos (sin/cos of x turns, iterative folded CORDIC; one datapath reused over ceil(K*100/UNROLL100) "
              "cycles + a shared linear-correction multiply, II = latency. The only DSPs are the 2*pi correction; it "
              "fits the LFE5U-25F many times over. UNROLL100=100: one iteration per cycle, the shortest path)",
        top="zkf_sincos_synth_top",
        kind="sincos",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        unroll100=100,    # one CORDIC iteration per engine cycle (shortest combinational path).
                          # PARALLEL auto-resolves to 0 here: a full-rate z-chain can't get ahead of a full-rate x/y, so
                          # the engine stays lock-step (forcing it would need a 2-deep z-chain that misses 100 MHz).
        stage_product=2,  # 2x2 + operand-capture split of the shared correction multiply -> 100 MHz.
        stage_normalize=2,  # both normshift barriers load-bearing (SN=1 reproducibly drops M18 to 99.5 MHz).
        stage_pack=1,     # rounder pack register; both it and the 2x2 product split are needed for 100 MHz.
    ),
    # WEXP=8, WMAN=36: same folded engine, more iterations on a wider datapath. Still the default LFE5U-25F (the
    # rotation array uses no DSPs; only the correction multiplies do).
    ModuleSpec(
        name="zkf_sincos_w8m36",
        label="zkf_sincos (WEXP=8, WMAN=36, iterative folded CORDIC; UNROLL100=50 + PARALLEL (auto: the decoupled "
              "full-rate z-path runs ahead so the PHI correction overlaps the CORDIC, -4 cycles) + STAGE_PRODUCT=3 "
              "(4x3 split) + STAGE_NORMALIZE=2 + STAGE_PACK=1; engine half-rate, 2 cycles/iteration; LFE5U-25F)",
        top="zkf_sincos_w8m36_synth_top",
        kind="sincos",
        wexp=8,
        wman=36,
        wexp_unbiased=0,
        unroll100=50,     # half-rate 2-cycle engine: the wide (XW=64) shift+add recurrence misses 100 MHz single-cycle.
                          # PARALLEL auto-resolves to 1: the full-rate z-path (1 iter/cycle) laps the half-rate x/y so
                          # the PHI correction overlaps the CORDIC, -4 cycles, with no Fmax or DSP cost.
        stage_product=3,  # row-sum staging for the shared correction multiply (depth/latency knob) -> 100 MHz.
        wmultiplier=18,   # 18-bit tile hint -> the 66x41 product derives a 4x3 single-tile grid (12 DSP) instead of
                          #   the symmetric 3x3's 18; latency-neutral.
        stage_normalize=2,
        stage_pack=1,
        emit_schematic=False,
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
        return [hdl / "_zkf_pack.v", hdl / "zkf_pipe.v", hdl / "_zkf_pmul.v", hdl / "zkf_mul.v"]
    if spec.kind == "add":
        return [
            hdl / "_zkf_pack.v",
            hdl / "zkf_pipe.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_add.v",
        ]
    if spec.kind == "addsub":
        return [
            hdl / "_zkf_pack.v",
            hdl / "zkf_pipe.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_add.v",
            hdl / "zkf_addsub.v",
        ]
    if spec.kind == "fma":
        return [
            hdl / "_zkf_pack.v",
            hdl / "zkf_pipe.v",
            hdl / "_zkf_pmul.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "zkf_fma.v",
        ]
    if spec.kind == "div_core":
        return [hdl / "_zkf_div_core.v"]
    if spec.kind == "div":
        return [
            hdl / "_zkf_pack.v",
            hdl / "zkf_pipe.v",
            hdl / "_zkf_div_core.v",
            hdl / "zkf_div.v",
        ]
    if spec.kind == "cmp":
        return [hdl / "zkf_pipe.v", hdl / "zkf_cmp_comb.v", hdl / "zkf_cmp.v"]
    if spec.kind == "sort":
        return [hdl / "zkf_pipe.v", hdl / "zkf_cmp_comb.v", hdl / "zkf_sort.v"]
    if spec.kind == "mul_ilog2_const":
        return [hdl / "zkf_pipe.v", hdl / "zkf_mul_ilog2_const.v"]
    if spec.kind == "from_int":
        return [
            hdl / "_zkf_pack.v",
            hdl / "zkf_pipe.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_fixed_to_float.v",
            hdl / "zkf_from_int.v",
        ]
    if spec.kind == "to_int":
        return [
            hdl / "zkf_pipe.v",
            hdl / "_zkf_rshift_sticky.v",
            hdl / "_zkf_to_fixpoint.v",
            hdl / "zkf_to_int.v",
        ]
    if spec.kind == "resize":
        return [
            hdl / "_zkf_pack.v",
            hdl / "zkf_pipe.v",
            hdl / "zkf_resize.v",
        ]
    if spec.kind == "round":
        return [
            hdl / "_zkf_pack.v",
            hdl / "zkf_pipe.v",
            hdl / "zkf_round.v",
        ]
    if spec.kind in {"exp2", "log2"}:
        # The generate-if selects the table whose name matches WMAN (the degree is a closed-form localparam inside the
        # table); the other WMAN branches reference undefined modules but are untaken, so synthesis prunes them (like
        # the _zkf_invalid_* sentinels). Yosys's hierarchy -check, however, also elaborates the *generic* zkf_<func>
        # (default WMAN), so that WMAN's table must be present too -- include both (deduped) and let synthesis prune
        # the unused generic.
        def table(wman: int) -> Path:
            return hdl / "_tables" / f"_zkf_{spec.kind}_m{wman}.v"
        DEFAULT_WMAN = 18  # the default WMAN of zkf_exp2 / zkf_log2
        tables = [table(w) for w in sorted({DEFAULT_WMAN, spec.wman})]
        sources = [hdl / "_zkf_pack.v", hdl / "zkf_pipe.v", hdl / "_zkf_pmul.v"]
        if spec.kind == "exp2":
            # exp2's _zkf_to_fixpoint helper uses _zkf_rshift_sticky for the right-shift path; the helper itself
            # owns the decode + folded-constant predicate cone shared with zkf_to_int.
            sources += [hdl / "_zkf_rshift_sticky.v", hdl / "_zkf_to_fixpoint.v"]
        if spec.kind == "log2":
            # log2's _zkf_fixed_to_float helper owns the _zkf_normshift instance (STAGE_SPLIT = 1 + STAGE_NORMALIZE)
            # plus the normshift -> pack-input combine -> _zkf_pack pipeline shared with zkf_from_int.
            sources += [hdl / "_zkf_normshift.v", hdl / "_zkf_fixed_to_float.v", hdl / "_zkf_log2_final_mul.v"]
        return sources + [hdl / "_zkf_horner.v", *tables, hdl / f"zkf_{spec.kind}.v"]
    if spec.kind == "sincos":
        # Left-shift turns reducer (inline) + octant fold + the shared CORDIC engine (_zkf_cordic) bound per WMAN
        # (_zkf_cordic_m<WMAN>) + the shared correction multiply (_zkf_pmul) + two _zkf_fixed_to_float back ends.
        # Include both the default-WMAN (18) core and this spec's WMAN, deduped, so Yosys's hierarchy -check is
        # satisfied for the generic zkf_sincos too.
        def core(wman: int) -> Path:
            return hdl / "_tables" / f"_zkf_cordic_m{wman}.v"
        cores = [core(w) for w in sorted({18, spec.wman})]  # 18 = the default WMAN of zkf_sincos
        return [
            hdl / "_zkf_pack.v",
            hdl / "zkf_pipe.v",
            hdl / "_zkf_normshift.v",
            hdl / "_zkf_fixed_to_float.v",
            hdl / "_zkf_pmul.v",
            hdl / "_zkf_cordic.v",
            *cores,
            hdl / "zkf_sincos.v",
        ]
    raise ValueError(f"unsupported module kind: {spec.kind}")


def div_qfrac(spec: ModuleSpec) -> int:
    return latency_div_qfrac(spec.wman)


def effective_parallel(spec: ModuleSpec) -> int:
    # Mirror the RTL PARALLEL default (= UNROLL100 < 100) when the spec leaves it on auto (-1).
    return spec.parallel if spec.parallel >= 0 else (1 if spec.unroll100 < 100 else 0)


def register_stages(spec: ModuleSpec) -> int:
    return module_latency(
        spec.kind,
        wman=spec.wman,
        unroll100=spec.unroll100,
        parallel=effective_parallel(spec),
        stage_input=spec.stage_input,
        stage_product=spec.stage_product,
        stage_align=spec.stage_align,
        stage_decode=spec.stage_decode,
        stage_normalize=spec.stage_normalize,
        stage_pack=spec.stage_pack,
        stage_output=spec.stage_output,
    )


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
    if spec.kind == "round":
        return (f"WEXP={spec.wexp}, WMAN={spec.wman}"
                f"{_si_suffix(spec)}{_sd_suffix(spec)}{_pa_suffix(spec)}{_so_suffix(spec)}")
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
