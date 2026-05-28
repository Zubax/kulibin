#!/usr/bin/env python3
"""
Coefficient generator for the ZKF transcendental operators ``zkf_log2`` and ``zkf_exp2``.

Both operators reduce to evaluating a smooth helper function on the unit interval with a per-segment polynomial:

  * exp2 evaluates ``H(s) = 2**s`` for ``s in [0,1)`` (the fractional part of the input); the result is the
    significand ``2**f in [1,2)``.

  * log2 evaluates ``P(t) = log2(1+t)/t`` for ``t in [0,1)`` (the input's stored fraction); ``log2(m) = t * P(t)``.
    Factoring out the exact ``t`` keeps full relative accuracy near ``m == 1`` without a doubled-width table.

The helper interval is split into ``2**K`` equal segments indexed by the top ``K`` argument bits; within a segment a
degree-``D`` polynomial in the segment-local coordinate ``wn in [0,1)`` is evaluated by a truncating fixed-point Horner
recurrence (see ``hdl/_zkf_horner.v``). ``D`` is a closed-form function of ``WMAN`` (so the pipeline depth is too); ``K``
is then the smallest segment count that meets the accuracy target with that degree, and affects only the ROM size.

This module is the single source of truth. ``--emit`` writes, per supported ``WMAN``, a self-contained per-table eval
core ``hdl/_tables/_zkf_<func>_m<WMAN>_d<D>.v`` plus the Python data table ``tb/zkf_trans_tables.py`` that the bit-exact
reference model imports. The public ``hdl/zkf_<func>.v`` modules carry a hand-written generate-if that enumerates every
``WMAN`` in [4, 53] and instantiates the matching table module; an un-pregenerated ``WMAN`` fails elaboration loudly
(the chosen table module is simply undefined). ``--check`` verifies the tables against an ``mpmath`` ground truth.

The table content depends on ``WMAN`` only (never ``WEXP``): the helper functions live on the unit interval and the
exponent/integer part is handled outside the table by the renormalize/pack stage.
"""

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass, field
from textwrap import dedent

import mpmath as mp

mp.mp.prec = 280  # generous working precision for coefficient fitting and ground-truth rounding

REPO = os.path.dirname(os.path.abspath(__file__))  # .../float
HDL = os.path.join(REPO, "hdl")
TABLES = os.path.join(HDL, "_tables")
TB = os.path.join(REPO, "tb")

FUNCS = ("exp2", "log2")

# WMAN values shipped with pre-generated tables: the verification-matrix formats plus the headline 18/24/36/53.
SUPPORTED_WMAN = [4, 5, 6, 7, 8, 11, 17, 18, 23, 24, 36, 53]
# Closed-form WMAN range the public modules enumerate. Any WMAN here without a pre-generated table file fails
# elaboration loudly (the selected _zkf_<func>_m<WMAN>_d<D> module is undefined); WMAN outside it hits a sentinel.
WMAN_MIN, WMAN_MAX = 4, 53

# Guard bits: fixed-point fractional headroom kept below the WMAN significand, common to both operators. Used as the
# reduced-argument fraction width (exp2: FF = WMAN + GUARD) and the coefficient/result scale (both: CF = WMAN + GUARD).
#
# Why 12: the operators must be faithfully rounded (<=1 ULP, targeting 0.5 ULP), so the value reaching the rounder must
# be trustworthy a few bits below the round position. The fit + truncating Horner is held to a relative error budget of
# ERR_GUARD = 8 bits below the ULP (see `target` in choose_spec); GUARD must sit ABOVE that noise floor by enough to
# host the guard and round bits and absorb the Horner's few-LSB truncation. GUARD = ERR_GUARD + 4 = 12 places the round
# bit ~7 bits clear of the approximation error, which the end-to-end mpmath `--check` confirms is sufficient for every
# supported WMAN (shrinking GUARD eventually breaks the faithful-rounding assertion). A single shared value suffices
# because both uses demand the same headroom; it is not a per-function quantity.
GUARD = 12
ERR_GUARD = 8   # helper relative-error budget exponent: target < 2**-(WMAN + ERR_GUARD)

K_CAP = 9       # max segment-index bits (table size 2**K)
ACC_MARGIN = 3  # extra accumulator bits above the measured maximum, guarding against wrap


def wfrac(wman: int) -> int:
    return wman - 1


def ff_bits(wman: int) -> int:
    return wman + GUARD


def cf_bits(wman: int) -> int:
    return wman + GUARD


def arg_bits(func: str, wman: int) -> int:
    """Reduced-argument width feeding the table: exp2 reduces to the FF-bit fraction f, log2 uses the WFRAC-bit
    stored fraction t. This is the *only* way the two functions differ in their shape selection."""
    return ff_bits(wman) if func == "exp2" else wfrac(wman)


def _ceil_div(a: int, b: int) -> int:
    return -(-a // b)


def degree(wman: int, argbits: int) -> int:
    """Polynomial degree as a closed-form integer function of WMAN and the reduced-argument width (so the pipeline
    depth is itself a closed-form function of WMAN, in the spirit of the divider's qfrac -- no chip-specific
    quantities). The per-segment polynomial must span a 2**-K-wide segment to B = WMAN + ERR_GUARD bits; with K capped
    by both K_CAP and the available argument bits (less one, so the reduced argument keeps >=1 bit), the minimal degree
    is ceil(B/Keff) - 1, floored at 2. Larger WMAN raises it via precision; a very narrow argument raises it via the
    coarse segmentation. There is deliberately no `func` selector: the dependence enters only through `argbits`, which
    is why exp2 and log2 diverge for small WMAN (log2's WFRAC-bit argument is far narrower than exp2's FF-bit one, so
    log2 needs a higher degree there) yet agree for WMAN >= 7."""
    keff = min(K_CAP, argbits - 1)
    return max(2, _ceil_div(wman + ERR_GUARD, keff) - 1)


def table_module(func: str, wman: int, d: int) -> str:
    return f"_zkf_{func}_m{wman}_d{d}"


@dataclass
class Spec:
    func: str            # "exp2" | "log2"
    wman: int
    k: int               # segment-index bits
    d: int               # polynomial degree
    cf: int              # coefficient fractional bits (scale 2**-cf)
    rw: int              # reduced-argument bits (wn = w / 2**rw)
    argbits: int         # total argument bits (FF for exp2, WFRAC for log2); argbits == k + rw
    cw: int              # signed coefficient width
    accw: int            # signed Horner accumulator width
    coeffs: list = field(default_factory=list)  # [2**k][d+1] signed ints, low degree first

    @property
    def nseg(self) -> int:
        return 1 << self.k


# --------------------------------------------------------------------------------------------------
# Coefficient fitting (high precision via mpmath)
# --------------------------------------------------------------------------------------------------
def helper_true(func: str, arg):
    """Exact helper value at unit-interval argument ``arg`` (mpf), high precision."""
    if func == "exp2":
        return mp.power(2, arg)
    # log2: P(t) = log2(1+t)/t, with the removable singularity P(0) = 1/ln2.
    if arg == 0:
        return 1 / mp.log(2)
    return mp.log(1 + arg) / (mp.log(2) * arg)


def segment_coeffs(func: str, k: int, d: int, cf: int, idx: int) -> list[int]:
    """Near-minimax degree-d coefficients (low degree first, scaled by 2**cf, rounded) for one segment."""
    base = mp.mpf(idx) / (1 << k)
    width = mp.mpf(1) / (1 << k)
    cheb = mp.chebyfit(lambda wn: helper_true(func, base + width * wn), [mp.mpf(0), mp.mpf(1)], d + 1)
    scale = mp.mpf(1 << cf)
    return [int(mp.nint(c * scale)) for c in reversed(cheb)]  # chebyfit is highest-degree first


def horner(coeffs_idx: list[int], w: int, rw: int) -> int:
    """Truncating fixed-point Horner, bit-identical to hdl/_zkf_horner.v. Returns acc at scale 2**-cf."""
    acc = coeffs_idx[-1]
    for c in reversed(coeffs_idx[:-1]):
        acc = c + ((acc * w) >> rw)  # Python >> floors, matching arithmetic >>> on signed
    return acc


def _arg_grid(argbits: int, k: int):
    """Argument values to probe: exhaustive when small, else dense segment-local sampling."""
    if argbits <= 16:
        return range(1 << argbits)
    rw = argbits - k
    span = 1 << rw
    probes = sorted({0, span // 7, span // 4, span // 2, (5 * span) // 7, (3 * span) // 4, span - 1})
    return [(idx << rw) | w for idx in range(1 << k) for w in probes]


def measure(func: str, wman: int, k: int, d: int, cf: int, coeffs: list[list[int]]):
    """Return (max relative helper error, max |accumulator| seen) over the probe grid, exercising the truncating
    Horner so that meeting the accuracy target guarantees faithful rounding by construction."""
    argbits = arg_bits(func, wman)
    rw = argbits - k
    scale = mp.mpf(1 << cf)
    max_rel, max_acc = mp.mpf(0), 0
    for a in _arg_grid(argbits, k):
        idx, w = a >> rw, a & ((1 << rw) - 1)
        ci = coeffs[idx]
        acc = ci[-1]
        max_acc = max(max_acc, abs(acc))
        for c in reversed(ci[:-1]):
            acc = c + ((acc * w) >> rw)
            max_acc = max(max_acc, abs(acc))
        approx = mp.mpf(acc) / scale
        true = helper_true(func, mp.mpf(a) / (1 << argbits))
        max_rel = max(max_rel, abs(approx / true - 1))
    return max_rel, max_acc


def choose_spec(func: str, wman: int) -> Spec:
    """With the degree fixed by the closed-form ``degree`` (so the pipeline depth is a closed-form function of WMAN),
    pick the smallest segment count K (smallest ROM) that meets the accuracy target. K affects only the ROM, not the
    depth. Accuracy is measured through the truncating Horner, so meeting the target guarantees faithful rounding."""
    cf = cf_bits(wman)
    argbits = arg_bits(func, wman)
    d = degree(wman, argbits)
    target = mp.mpf(2) ** (-(wman + ERR_GUARD))  # relative helper-error budget

    for k in range(1, min(K_CAP, argbits - 1) + 1):
        coeffs = [segment_coeffs(func, k, d, cf, idx) for idx in range(1 << k)]
        rel, max_acc = measure(func, wman, k, d, cf, coeffs)
        if rel < target:
            maxabs = max(abs(c) for seg in coeffs for c in seg)
            cw = maxabs.bit_length() + 2                          # +1 sign, +1 margin
            accw = max(max_acc, maxabs).bit_length() + 1 + ACC_MARGIN
            return Spec(func, wman, k, d, cf, argbits - k, argbits, cw, accw, coeffs)
    raise RuntimeError(f"degree {d} needs K>{K_CAP} for {func} WMAN={wman}: raise the degree() floor or K_CAP")


def generate_all() -> dict[tuple[str, int], Spec]:
    return {(func, wman): choose_spec(func, wman) for func in FUNCS for wman in SUPPORTED_WMAN}


# --------------------------------------------------------------------------------------------------
# Verilog emission
# --------------------------------------------------------------------------------------------------
class _Writer:
    """Accumulates 4-space-indented lines; ``w(...)`` accepts single lines or dedented multiline blocks."""

    def __init__(self) -> None:
        self._lines: list[str] = []
        self._depth = 0

    def __call__(self, *texts: str) -> None:
        for text in texts:
            if "\n" in text:
                block = dedent(text).removeprefix("\n").removesuffix("\n")
                for line in block.split("\n"):
                    self._append(line)
            else:
                self._append(text)

    def _append(self, text: str) -> None:
        self._lines.append(("    " * self._depth + text) if text else "")

    def push(self) -> None:
        self._depth += 1

    def pop(self) -> None:
        assert self._depth > 0
        self._depth -= 1

    def render(self) -> str:
        return "\n".join(self._lines) + "\n"


def _rom_rows(w: _Writer, s: Spec) -> None:
    """Emit the coefficient ROM: one packed word per segment, rom[seg] = {c[D], ..., c[0]}, one (wide) line each."""
    if s.nseg <= 16:
        # A small table is a shallow x wide shape that wastes a whole BRAM at <1% utilization, so hint soft logic;
        # larger tables (NSEG >= 32) keep the inferred BRAM. Attribute only -- contents and timing are unchanged.
        w('(* rom_style = "logic", syn_romstyle = "logic" *)')
    w("reg [(D+1)*CW-1:0] rom [0:NSEG-1];")
    w("initial begin")
    w.push()
    for seg in range(s.nseg):
        word = ", ".join(f"{s.cw}'h{c & ((1 << s.cw) - 1):0{(s.cw + 3) // 4}x}"
                          for c in reversed(s.coeffs[seg]))  # c[D] .. c[0]
        w(f"rom[{seg}] = {{{word}}};")
    w.pop()
    w("end")


def _rom_read_pipeline(w: _Writer, sb_load: str) -> None:
    """Emit the 2-deep registered ROM read: r_co1 is the synchronous (BRAM) read register with a slow clk-to-q on
    ECP5; r_co2 is a fabric register isolating that delay from the first Horner multiply. w/sideband/valid ride along."""
    w("""
        reg [(D+1)*CW-1:0] r_co1, r_co2;
        reg        [RW-1:0] r_w1, r_w2;
        reg                 r_rv1, r_rv2;
        reg      [HSBW-1:0] r_rsb1, r_rsb2;
        always @(posedge clk) begin
    """.strip("\n"))
    w.push()
    w("if (rst) begin r_rv1 <= 1'b0; r_rv2 <= 1'b0; end")
    w("else     begin r_rv1 <= in_valid; r_rv2 <= r_rv1; end")
    w("r_co1  <= rom[idx]; r_co2  <= r_co1;")
    w("r_w1   <= w;        r_w2   <= r_w1;")
    w(f"r_rsb1 <= {sb_load}; r_rsb2 <= r_rsb1;")
    w.pop()
    w("end")
    w("""
        wire signed [ACCW-1:0] acc;
        wire                   ev;
        wire      [HSBW-1:0]   esb;
        // verilator coverage_on
        _zkf_horner #(.D(D), .CW(CW), .RW(RW), .ACCW(ACCW), .SBW(HSBW), .STAGE_PRODUCT(STAGE_PRODUCT)) u_h (
            .clk(clk), .rst(rst), .in_valid(r_rv2), .sb_in(r_rsb2), .coeffs(r_co2), .w(r_w2),
            .out_valid(ev), .sb_out(esb), .acc(acc));
    """.strip("\n"))


def _emit_table(s: Spec) -> str:
    """One self-contained per-WMAN evaluation core. Shape (K/D/CF/RW/CW/ACCW) is baked; only SBW and STAGE_PRODUCT
    are parameters. zkf_<func>.v selects the module whose name matches its WMAN/degree."""
    mod = table_module(s.func, s.wman, s.d)
    w = _Writer()
    w("/// GENERATED by float/zkf_transcendental.py -- DO NOT EDIT.")
    if s.func == "exp2":
        w(f"/// Table+polynomial core for zkf_exp2 at WMAN={s.wman} (degree {s.d}); zero-bubble, see _zkf_horner.",
          "/// Evaluates the significand 2**f in [1,2) from the reduced fractional argument f (FF = WMAN + 12 bits).",
          "/// Register stages: 2 (ROM read) + D*(2+STAGE_PRODUCT) (Horner); valid and sb_in are delayed to match.")
    else:
        w(f"/// Table+polynomial core for zkf_log2 at WMAN={s.wman} (degree {s.d}); zero-bubble, see _zkf_horner.",
          "/// Evaluates log2(1+t) = t*P(t) as a fixed-point fraction (scale 2**-F2); P(t)=log2(1+t)/t via the table.",
          "/// Register stages: 2 (ROM read) + D*(2+STAGE_PRODUCT) (Horner) + 1 (final multiply); valid/sb_in match.")
    w("")
    w("// verilog_lint: waive-start line-length  (the ROM rows are wide one-liners)")
    w("")
    w("`default_nettype none")
    w("")
    w(f"module {mod} #(parameter integer WMAN = {s.wman}, parameter integer SBW = 1, parameter integer STAGE_PRODUCT = 0) (")
    w.push()
    if s.func == "exp2":
        w("""
            input  wire                   clk,
            input  wire                   rst,
            input  wire                   in_valid,
            input  wire        [SBW-1:0]  sb_in,
            input  wire [WMAN+12-1:0]     f,            // FF = WMAN + 12 reduced-argument fraction bits, in [0,1)
            output wire                   out_valid,
            output wire        [SBW-1:0]  sb_out,
            output wire        [WMAN-1:0] significand,  // 2**f in [1,2): hidden bit + WFRAC fraction
            output wire                   guard,
            output wire                   round,
            output wire                   sticky
        """.strip("\n"))
    else:
        w("""
            input  wire                   clk,
            input  wire                   rst,
            input  wire                   in_valid,
            input  wire        [SBW-1:0]  sb_in,
            input  wire        [WMAN-2:0] frac,         // stored fraction t (WFRAC = WMAN-1 bits), in [0,1)
            output wire                   out_valid,
            output wire        [SBW-1:0]  sb_out,
            output wire [2*WMAN+12-2:0]   l_fix         // log2(1+t) at scale 2**-F2, F2 = WFRAC + CF, in [0,1)
        """.strip("\n"))
    w.pop()
    w(");")
    w.push()
    # Shape localparams (baked); the public module hard-codes the matching FF/CF so it need not know K/D.
    if s.func == "exp2":
        w("localparam integer FF   = WMAN + 12;")
    else:
        w("localparam integer WFRAC = WMAN - 1;",
          "localparam integer CF    = WMAN + 12;",
          "localparam integer F2    = WFRAC + CF;")
    w(f"localparam integer K    = {s.k};")
    w(f"localparam integer D    = {s.d};")
    if s.func == "exp2":
        w(f"localparam integer CF   = {s.cf};")
    w(f"localparam integer RW   = {s.rw};")
    w(f"localparam integer CW   = {s.cw};")
    w(f"localparam integer ACCW = {s.accw};")
    w(f"localparam integer NSEG = {s.nseg};")
    if s.func == "exp2":
        w("localparam integer HSBW = SBW;")
    else:
        w("localparam integer HSBW = SBW + WFRAC;  // carry t alongside the sideband to the final multiply")
    w("")
    w("// verilator coverage_off")
    _rom_rows(w, s)
    if s.func == "exp2":
        w("wire [K-1:0]  idx = f[FF-1 -: K];")
        w("wire [RW-1:0] w   = f[RW-1:0];")
        _rom_read_pipeline(w, "sb_in")
        # acc scale 2^-CF, value 2^f in [1,2): bit CF is the hidden one. Output is combinational after the Horner.
        w("""
            assign significand = acc[CF -: WMAN];
            assign guard       = acc[CF-WMAN];
            assign round       = acc[CF-WMAN-1];
            assign sticky      = |acc[CF-WMAN-2:0];
            assign out_valid   = ev;
            assign sb_out      = esb;
        """.strip("\n"))
    else:
        w("wire [K-1:0]  idx = frac[WFRAC-1 -: K];")
        w("wire [RW-1:0] w   = frac[RW-1:0];")
        _rom_read_pipeline(w, "{sb_in, frac}")
        # l = t * P = frac * acc (acc > 0), scale 2^-F2 in [0,1). The split-aware multiply lives in
        # _zkf_log2_final_mul so the SP={0,1,2} story is the same as the Horner: depth = 1 + STAGE_PRODUCT stages.
        w("""
            wire [WFRAC-1:0] frac_p = esb[WFRAC-1:0];
            wire [SBW-1:0]   sb_p   = esb[HSBW-1 -: SBW];
            // verilator coverage_on
            _zkf_log2_final_mul #(.WFRAC(WFRAC), .ACCW(ACCW), .F2(F2), .SBW(SBW), .STAGE_PRODUCT(STAGE_PRODUCT)) u_tp (
                .clk(clk), .rst(rst), .in_valid(ev), .sb_in(sb_p), .frac(frac_p), .acc(acc),
                .out_valid(out_valid), .sb_out(sb_out), .l_fix(l_fix));
        """.strip("\n"))
    w.pop()
    w("endmodule")
    w("")
    w("// verilog_lint: waive-stop line-length")
    w("`default_nettype wire")
    return w.render()


def _emit_python(all_specs: dict[tuple[str, int], Spec]) -> str:
    w = _Writer()
    w("# GENERATED by float/zkf_transcendental.py -- DO NOT EDIT.")
    w('"""Bit-exact table+polynomial data for zkf_log2 / zkf_exp2, consumed by zkf_model.py."""')
    w("")
    w("SPECS = {")
    w.push()
    for (func, wman) in sorted(all_specs):
        s = all_specs[(func, wman)]
        w(f"({func!r}, {wman}): dict(")
        w.push()
        w(f"k={s.k}, d={s.d}, cf={s.cf}, rw={s.rw}, argbits={s.argbits}, cw={s.cw}, accw={s.accw},")
        w(f"coeffs={s.coeffs!r},")
        w.pop()
        w("),")
    w.pop()
    w("}")
    w("")
    w(f"GUARD_FF = {GUARD}")
    w(f"GUARD_CF = {GUARD}")
    w("")
    w("""
        def get_spec(func, wman):
            try:
                return SPECS[(func, wman)]
            except KeyError:
                raise KeyError(f'no {func} table for WMAN={wman}; run float/zkf_transcendental.py --emit')
    """.strip("\n"))
    return w.render()


def emit(all_specs: dict[tuple[str, int], Spec]) -> None:
    os.makedirs(TABLES, exist_ok=True)
    for (func, wman), s in sorted(all_specs.items()):
        path = os.path.join(TABLES, f"{table_module(func, wman, s.d)}.v")
        with open(path, "w") as fh:
            fh.write(_emit_table(s))
        print(f"wrote {os.path.relpath(path, REPO)}")
    path = os.path.join(TB, "zkf_trans_tables.py")
    with open(path, "w") as fh:
        fh.write(_emit_python(all_specs))
    print(f"wrote {os.path.relpath(path, REPO)}")


# --------------------------------------------------------------------------------------------------
# Reporting and accuracy check
# --------------------------------------------------------------------------------------------------
def _report(all_specs: dict[tuple[str, int], Spec]) -> None:
    print(f"{'func':5} {'WMAN':>4} {'K':>3} {'D':>3} {'CF':>4} {'RW':>4} {'CW':>4} {'ACCW':>5} {'entries':>8} {'ROM_kbit':>9}")
    for (func, wman), s in sorted(all_specs.items()):
        entries = s.nseg * (s.d + 1)
        print(f"{func:5} {wman:>4} {s.k:>3} {s.d:>3} {s.cf:>4} {s.rw:>4} {s.cw:>4} {s.accw:>5} "
              f"{entries:>8} {entries * s.cw / 1024.0:>9.1f}")

    # The public modules enumerate WMAN in [WMAN_MIN, WMAN_MAX]; show the degree map so the hand-written generate-if in
    # hdl/zkf_<func>.v can be cross-checked. A pre-generated WMAN whose degree changed would name a now-missing module.
    print(f"\ndegree map for the zkf_<func>.v generate-if ({WMAN_MAX - WMAN_MIN + 1} lines each):")
    for func in FUNCS:
        d_map = " ".join(f"{wman}:{degree(wman, arg_bits(func, wman))}" for wman in range(WMAN_MIN, WMAN_MAX + 1))
        print(f"  {func}: {d_map}")


def _check(all_specs: dict[tuple[str, int], Spec]) -> None:
    """End-to-end accuracy check vs mpmath via the bit-exact model. Requires tb/ on sys.path."""
    import sys
    sys.path.insert(0, TB)
    import importlib
    import zkf_model
    importlib.reload(zkf_model)
    from zkf_model import ZkfFormat, exp2_reference, log2_reference, exp2_true, log2_true
    import numpy as np

    print("end-to-end correct-rounding check (model vs mpmath):")
    cases = [(2, 4), (3, 4), (3, 5), (4, 6), (5, 6), (5, 11), (8, 24)]  # small: exhaustive; large: random
    for wexp, wman in cases:
        if wman not in SUPPORTED_WMAN:
            continue
        fmt = ZkfFormat(wexp, wman)
        n = 1 << fmt.wfull
        exhaustive = n <= (1 << 16)
        inputs = list(range(n)) if exhaustive else \
            [int(x) for x in np.random.default_rng(0xC0FFEE).integers(0, n, 20000)]
        for func, ref, true in (("exp2", exp2_reference, exp2_true), ("log2", log2_reference, log2_true)):
            worst = ne = 0
            for b in inputs:
                got, want = ref(fmt, b), true(fmt, b)
                got_bits = got[0] if isinstance(got, tuple) else got
                want_bits = want[0] if isinstance(want, tuple) else want
                ulp = _ulp_diff(fmt, got_bits, want_bits)
                worst = max(worst, ulp)
                ne += ulp > 0
            tag = "exhaustive" if exhaustive else f"random({len(inputs)})"
            status = "OK " if worst <= 1 else "BAD"
            print(f"  {status} {func} {wexp}/{wman:<3} max_ulp={worst} mismatches={ne}/{len(inputs)} ({tag})")
            assert worst <= 1, f"{func} {wexp}/{wman}: max ULP {worst} > 1 (faithful-rounding contract violated)"


def _ulp_diff(fmt, a_bits: int, b_bits: int) -> int:
    """Magnitude of the difference between two ZKF encodings in ULPs along the ordered number line."""
    return 0 if a_bits == b_bits else abs(_ordered_index(fmt, a_bits) - _ordered_index(fmt, b_bits))


def _ordered_index(fmt, bits: int) -> int:
    """Monotonic integer index of a canonical ZKF value (sign-magnitude -> ordered)."""
    import zkf_model
    bits = zkf_model.canonicalize_special(fmt, bits)
    sign = (bits >> fmt.sign_shift) & 1
    mag = bits & ((1 << fmt.sign_shift) - 1)
    return -mag if sign else mag


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--emit", action="store_true", help="write the per-table Verilog cores and Python data table")
    ap.add_argument("--check", action="store_true", help="verify accuracy vs mpmath (uses the bit-exact model)")
    ap.add_argument("--report", action="store_true", help="print the chosen table shapes and the degree map")
    args = ap.parse_args()
    if not (args.emit or args.check or args.report):
        ap.error("nothing to do: pass --emit, --check, and/or --report")

    all_specs = generate_all()
    if args.report or args.emit:
        _report(all_specs)
    if args.emit:
        emit(all_specs)
    if args.check:
        _check(all_specs)


if __name__ == "__main__":
    main()
