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
recurrence (see ``hdl/_zkf_horner.v``). ``D`` is a closed-form function of ``WMAN`` (so the pipeline depth is too);
``K`` is then the smallest segment count meeting the accuracy target at that degree, and affects only the ROM size.

This module is the single source of truth. ``--emit`` writes, per supported ``WMAN``, a self-contained per-table eval
core ``hdl/_tables/_zkf_<func>_m<WMAN>.v`` plus the Python data table ``tb/zkf_trans_tables.py`` that the bit-exact
reference model imports. The public ``hdl/zkf_<func>.v`` modules carry a hand-written generate-if that enumerates every
``WMAN`` in [11, 53] and instantiates the matching table module, passing the closed-form degree the table asserts
against its ROM (mirroring the ``LATENCY`` parameter); an un-pregenerated ``WMAN`` fails elaboration loudly (the chosen
table module is simply undefined). ``--check`` verifies the tables against an ``mpmath`` ground truth.

The table content depends on ``WMAN`` only (never ``WEXP``): the helper functions live on the unit interval and the
exponent/integer part is handled outside the table by the renormalize/pack stage.
"""

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass, field
from math import ceil
from pathlib import Path
from textwrap import dedent

import mpmath as mp

mp.mp.prec = 280  # generous working precision for coefficient fitting and ground-truth rounding

REPO = Path(__file__).resolve().parent  # .../float
HDL = REPO / "hdl"
TABLES = HDL / "_tables"
TB = REPO / "tb"

FUNCS = ("exp2", "log2")

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

# Segment-index bits: the unit interval is split into 2**K_CAP equal segments, indexed by the top K_CAP bits of the
# reduced argument; the remaining bits feed the per-segment polynomial. K_CAP is the single ROM-size knob (2**K_CAP
# words) and, being constant for every supported WMAN, makes the per-segment degree a closed-form function of WMAN
# alone (see degree()). BRAM is cheap, so this is a deliberate area-for-latency trade: a larger K_CAP would lower the
# degree (shorter Horner pipeline) at the cost of a wider ROM.
K_CAP = 9
ACC_MARGIN = 3  # extra accumulator bits above the measured maximum, guarding against wrap

# Minimum supported WMAN. degree() peels K_CAP segment-index bits off the reduced argument and needs >=1 bit left for
# the in-segment coordinate, so the argument must be >= K_CAP + 1 bits wide. exp2's argument is the FF = WMAN + GUARD
# bit reduced fraction (always wide enough); log2's is the stored fraction WFRAC = WMAN - 1, which needs WMAN - 1 >=
# K_CAP + 1, i.e. WMAN >= K_CAP + 2 = 11 -- exactly binary16's significand precision (10 stored + 1 hidden). At and
# above it both functions keep the full K_CAP segments and share one degree formula; below it log2's narrower fraction
# can no longer fill K_CAP segments and would force a higher per-segment degree (the old per-function divergence).
# The public hdl/zkf_<func>.v modules enumerate this closed-form range; a WMAN in it without a pre-generated table
# fails elaboration loudly (the named _zkf_<func>_m<WMAN> module is undefined), and WMAN outside it hits a sentinel.
WMAN_MIN, WMAN_MAX = K_CAP + 2, 53

# WMAN values shipped with pre-generated tables: binary16 precision (11) through the most common ones, including
# FPGA-friendly significand sizes and the standard IEEE 754 ones. New ones can be added easily.
SUPPORTED_WMAN = [11, 16, 18, 24, 27, 32, 36, 48, 53]

# Random faithful-rounding samples per (format, operator) drawn in the --check for non-exhaustive formats. The RNG is
# UNSEEDED (true randomness) so every run explores fresh inputs and repeated runs accumulate coverage; any miss prints
# the offending input. The default is deliberately thorough -- override with ZKF_CHECK_SAMPLES=<n> for a quicker run.
RANDOM_CHECK_SAMPLES = int(os.environ.get("ZKF_CHECK_SAMPLES", "1000000"))


def ff_bits(wman: int) -> int:
    return wman + GUARD


def cf_bits(wman: int) -> int:
    return wman + GUARD


def degree(wman: int) -> int:
    """
    Per-segment polynomial degree, a closed-form function of WMAN alone, so the Horner pipeline depth is too.

    Each of the 2**K_CAP segments spans 2**-K_CAP of the unit interval, and its polynomial must approximate the helper
    there to B = WMAN + ERR_GUARD bits; the minimal degree spanning B bits across K_CAP segment-index bits is
    ceil(B / K_CAP) - 1. There is no `func` selector and no argument-width parameter: for WMAN >= 11 (see WMAN_MIN)
    both exp2 and log2 retain the full K_CAP segment-index bits.
    """
    if not (WMAN_MIN <= wman <= WMAN_MAX):
        raise ValueError(f"Bad {wman=}")
    d = ceil((wman + ERR_GUARD) / K_CAP) - 1
    assert d >= 2, "Maybe WMAN is too small or K_CAP is too large?"
    return d


def table_module(func: str, wman: int) -> str:
    return f"_zkf_{func}_m{wman}"


@dataclass
class Spec:
    func: str            # "exp2" | "log2"
    wman: int
    k: int               # segment-index bits
    d: int               # polynomial degree
    cf: int              # coefficient fractional bits (scale 2**-cf)
    rw: int              # reduced-argument bits (wn = w / 2**rw); the total argument width is k + rw
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


def _arg_grid(width: int, k: int):
    """Argument values to probe: exhaustive when small, else dense segment-local sampling."""
    if width <= 16:
        return range(1 << width)
    rw = width - k
    span = 1 << rw
    probes = sorted({0, span // 7, span // 4, span // 2, (5 * span) // 7, (3 * span) // 4, span - 1})
    return [(idx << rw) | w for idx in range(1 << k) for w in probes]


def measure(func: str, k: int, cf: int, width: int, coeffs: list[list[int]]):
    """
    Return (max relative helper error, max |accumulator| seen) over the probe grid, exercising the truncating
    Horner so that meeting the accuracy target guarantees faithful rounding by construction.
    """
    rw = width - k
    scale = mp.mpf(1 << cf)
    max_rel, max_acc = mp.mpf(0), 0
    for a in _arg_grid(width, k):
        idx, w = a >> rw, a & ((1 << rw) - 1)
        ci = coeffs[idx]
        acc = ci[-1]
        max_acc = max(max_acc, abs(acc))
        for c in reversed(ci[:-1]):
            acc = c + ((acc * w) >> rw)
            max_acc = max(max_acc, abs(acc))
        approx = mp.mpf(acc) / scale
        true = helper_true(func, mp.mpf(a) / (1 << width))
        max_rel = max(max_rel, abs(approx / true - 1))
    return max_rel, max_acc


def choose_spec(func: str, wman: int) -> Spec:
    """
    With the degree fixed by the closed-form ``degree`` (so the pipeline depth is a closed-form function of WMAN),
    pick the smallest segment count K (smallest ROM) that meets the accuracy target. K affects only the ROM, not the
    depth. Accuracy is measured through the truncating Horner, so meeting the target guarantees faithful rounding.
    For WMAN >= 11 both functions keep the full K_CAP segment-index bits, so K is searched over 1..K_CAP.
    """
    cf = cf_bits(wman)
    width = ff_bits(wman) if func == "exp2" else (wman - 1)  # reduced-argument width feeding the table
    d = degree(wman)
    target = mp.mpf(2) ** (-(wman + ERR_GUARD))  # relative helper-error budget

    for k in range(1, K_CAP + 1):
        coeffs = [segment_coeffs(func, k, d, cf, idx) for idx in range(1 << k)]
        rel, max_acc = measure(func, k, cf, width, coeffs)
        if rel < target:
            maxabs = max(abs(c) for seg in coeffs for c in seg)
            cw = maxabs.bit_length() + 2                          # +1 sign, +1 margin
            accw = max(max_acc, maxabs).bit_length() + 1 + ACC_MARGIN
            return Spec(func, wman, k, d, cf, width - k, cw, accw, coeffs)
    raise RuntimeError(f"degree {d} needs K>K_CAP={K_CAP} for {func} WMAN={wman}: raise K_CAP")


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
    # ROM inference hint by size: tiny tables stay in soft logic, larger ones map to block RAM. Portable, vendor-neutral
    # attribute only -- contents and timing are unchanged.
    if s.nseg <= 16:
        w('(* rom_style = "logic" *) // keep a small table in logic')
    else:
        w('(* rom_style = "block" *)  // map a large table to block RAM')
    w("reg [(D+1)*CW-1:0] rom [0:NSEG-1];")
    w("initial begin")
    w.push()
    for seg in range(s.nseg):  # c[D] .. c[0]
        word = ", ".join(f"{s.cw}'h{c & ((1 << s.cw) - 1):0{(s.cw + 3) // 4}x}" for c in reversed(s.coeffs[seg]))
        w(f"rom[{seg:3}] = {{{word}}};")
    w.pop()
    w("end")


def _rom_read_pipeline(w: _Writer, sb_load: str) -> None:
    """
    Emit the 2-deep registered ROM read: r_co1 is the synchronous (BRAM) read register with a slow clk-to-q on
    ECP5; r_co2 is a fabric register isolating that delay from the first Horner multiply. w/sideband/valid ride along.
    """
    w("""
        reg [(D+1)*CW-1:0] r_co1, r_co2;
        reg        [RW-1:0] r_w1, r_w2;
        reg                 r_rv1, r_rv2;
        reg      [HSBW-1:0] r_rsb1, r_rsb2;
        always @(posedge clk) begin
    """)
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
        _zkf_horner #(.D(D), .WCOEF(CW), .WRARG(RW), .WACC(ACCW), .WSB(HSBW), .STAGE_PRODUCT(STAGE_PRODUCT), .WMULTIPLIER(WMULTIPLIER)) u_h (
            .clk(clk), .rst(rst), .in_valid(r_rv2), .sb_in(r_rsb2), .coeffs(r_co2), .w(r_w2),
            .out_valid(ev), .sb_out(esb), .acc(acc));
    """)


def _emit_table(s: Spec) -> str:
    """
    One self-contained per-WMAN evaluation core. Shape (K/CF/RW/CW/ACCW) is baked; the degree D is a parameter
    defaulting to this ROM's fitted degree, which zkf_<func>.v drives with its own closed-form degree and the table
    asserts (mirroring the LATENCY parameter). zkf_<func>.v selects the module whose name matches its WMAN.
    """
    mod = table_module(s.func, s.wman)
    w = _Writer()
    w("/// GENERATED by float/zkf_transcendental.py -- DO NOT EDIT.")
    if s.func == "exp2":
        w(f"/// Table+polynomial core for zkf_exp2 at WMAN={s.wman} (degree {s.d}); zero-bubble, see _zkf_horner.",
          "/// Evaluates the significand 2**f in [1,2) from the reduced fractional argument f (FF = WMAN + 12 bits).",
          "/// Register stages: 2 (ROM read) + D*(2+STAGE_PRODUCT) (Horner); valid and sb_in are delayed to match.")
    else:
        w(f"/// Table+polynomial core for zkf_log2 at WMAN={s.wman} (degree {s.d}); zero-bubble, see _zkf_horner.",
          "/// Evaluates log2(1+t) = t*P(t) as a fixed-point fraction (scale 2**-F2); P(t)=log2(1+t)/t via the table.",
          "/// Register stages: 2 (ROM read) + D*(2+STAGE_PRODUCT) (Horner) + _zkf_log2_final_mul; valid/sb_in match.")
    w("")
    w("// verilog_lint: waive-start line-length  (the ROM rows are wide one-liners)")
    w("")
    w("`default_nettype none")
    w("")
    if s.func == "exp2":
        w(f"module {mod} #(parameter integer WMAN = {s.wman}, parameter integer D = {s.d}, "
          "parameter integer WSB = 1, parameter integer STAGE_PRODUCT = 0, parameter integer WMULTIPLIER = 0) (")
    else:
        w(f"module {mod} #(parameter integer WMAN = {s.wman}, parameter integer D = {s.d}, "
          "parameter integer WSB = 1, parameter integer STAGE_PRODUCT = 0, parameter integer WMULTIPLIER = 0) (")
    w.push()
    if s.func == "exp2":
        w("""
            input  wire               clk,
            input  wire               rst,
            input  wire               in_valid,
            input  wire     [WSB-1:0] sb_in,
            input  wire [WMAN+12-1:0] f,            // FF = WMAN + 12 reduced-argument fraction bits, in [0,1)
            output wire               out_valid,
            output wire     [WSB-1:0] sb_out,
            output wire    [WMAN-1:0] significand,  // 2**f in [1,2): hidden bit + WFRAC fraction
            output wire               guard,
            output wire               round,
            output wire               sticky
        """)
    else:
        w("""
            input  wire                 clk,
            input  wire                 rst,
            input  wire                 in_valid,
            input  wire       [WSB-1:0] sb_in,
            input  wire      [WMAN-2:0] frac,         // stored fraction t (WFRAC = WMAN-1 bits), in [0,1)
            output wire                 out_valid,
            output wire       [WSB-1:0] sb_out,
            output wire [2*WMAN+12-2:0] l_fix         // log2(1+t) at scale 2**-F2, F2 = WFRAC + CF, in [0,1)
        """)
    w.pop()
    w(");")
    w.push()
    # Blanket coverage_off over the whole module body (re-enabled just before endmodule): these are pure generated
    # data tables, exhaustively checked against the mpmath model by --check, not through HDL line/toggle coverage.
    w("// verilator coverage_off")
    # Degree contract (mirrors the LATENCY parameter): D defaults to this ROM's fitted degree and zkf_<func>.v drives
    # it with its own closed-form degree; a mismatch fails elaboration, so the Horner pipeline depth -- hence the
    # operator latency -- cannot silently drift from the degree the ROM was actually fitted for.
    w(f"generate if (D != {s.d}) begin : g_degree_mismatch  _zkf_invalid_degree_mismatch u_invalid(); end endgenerate")
    # Shape localparams (baked); the public module hard-codes the matching FF/CF so it need not know K.
    if s.func == "exp2":
        w("localparam integer FF   = WMAN + 12;")
    else:
        w("localparam integer WFRAC = WMAN - 1;",
          "localparam integer CF    = WMAN + 12;",
          "localparam integer F2    = WFRAC + CF;")
    w(f"localparam integer K    = {s.k};")
    if s.func == "exp2":
        w(f"localparam integer CF   = {s.cf};")
    w(f"localparam integer RW   = {s.rw};")
    w(f"localparam integer CW   = {s.cw};")
    w(f"localparam integer ACCW = {s.accw};")
    w(f"localparam integer NSEG = {s.nseg};")
    if s.func == "exp2":
        w("localparam integer HSBW = WSB;")
    else:
        w("localparam integer HSBW = WSB + WFRAC;  // carry t alongside the sideband to the final multiply")
    w("")
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
        """)
    else:
        w("wire [K-1:0]  idx = frac[WFRAC-1 -: K];")
        w("wire [RW-1:0] w   = frac[RW-1:0];")
        _rom_read_pipeline(w, "{sb_in, frac}")
        # l = t * P = frac * acc (acc > 0), scale 2^-F2 in [0,1). The split-aware multiply lives in
        # _zkf_log2_final_mul and follows the same linear STAGE_PRODUCT depth contract as the Horner.
        w("""
            wire [WFRAC-1:0] frac_p = esb[WFRAC-1:0];
            wire [WSB-1:0]   sb_p   = esb[HSBW-1 -: WSB];
            _zkf_log2_final_mul #(.WFRAC(WFRAC), .WACC(ACCW), .F2(F2), .WSB(WSB), .STAGE_PRODUCT(STAGE_PRODUCT), .WMULTIPLIER(WMULTIPLIER)) u_tp (
                .clk(clk), .rst(rst), .in_valid(ev), .sb_in(sb_p), .frac(frac_p), .acc(acc),
                .out_valid(out_valid), .sb_out(sb_out), .l_fix(l_fix));
        """)
    w("// verilator coverage_on")
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
        w(f"k={s.k}, d={s.d}, cf={s.cf}, rw={s.rw}, cw={s.cw}, accw={s.accw},")
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
    """)
    return w.render()


def emit(all_specs: dict[tuple[str, int], Spec]) -> None:
    TABLES.mkdir(parents=True, exist_ok=True)
    for (func, wman), s in sorted(all_specs.items()):
        path = TABLES / f"{table_module(func, wman)}.v"
        path.write_text(_emit_table(s))
        print(f"wrote {path.relative_to(REPO)}")
    path = TB / "zkf_trans_tables.py"
    path.write_text(_emit_python(all_specs))
    print(f"wrote {path.relative_to(REPO)}")


# --------------------------------------------------------------------------------------------------
# Reporting and accuracy check
# --------------------------------------------------------------------------------------------------
def _report(all_specs: dict[tuple[str, int], Spec]) -> None:
    print(f"{'func':5} {'WMAN':>4} {'K':>3} {'D':>3} {'CF':>4} {'RW':>4} "
          f"{'CW':>4} {'ACCW':>5} {'entries':>8} {'ROM_kbit':>9}")
    for (func, wman), s in sorted(all_specs.items()):
        entries = s.nseg * (s.d + 1)
        print(f"{func:5} {wman:>4} {s.k:>3} {s.d:>3} {s.cf:>4} {s.rw:>4} {s.cw:>4} {s.accw:>5} "
              f"{entries:>8} {entries * s.cw / 1024.0:>9.1f}")

    # zkf_<func>.v derives the degree D = (WMAN+16)/9 - 1 closed-form at elaboration (the ZKF_<func>_DEGREE macro,
    # matching degree() above), so the module name need not encode it. The map is a cross-check for that value; it is
    # identical for exp2 and log2 (degree does not depend on the function).
    d_map = " ".join(f"{wman}:{degree(wman)}" for wman in range(WMAN_MIN, WMAN_MAX + 1))
    print(f"\nclosed-form degree D = (WMAN+16)/9 - 1 derived in zkf_<func>.v "
          f"({WMAN_MAX - WMAN_MIN + 1} values, same for both):\n  {d_map}")


def _check(all_specs: dict[tuple[str, int], Spec]) -> None:
    """End-to-end accuracy check vs mpmath via the bit-exact model. Requires tb/ on sys.path."""
    import sys
    sys.path.insert(0, str(TB))
    import importlib
    import zkf_model
    importlib.reload(zkf_model)
    from zkf_model import ZkfFormat, exp2_reference, log2_reference, exp2_true, log2_true
    import numpy as np

    print("end-to-end correct-rounding check (model vs mpmath):")
    cases = [(5, 11), (6, 16), (8, 24), (8, 36), (8, 48)]  # binary16 (5/11) exhaustive; wider formats random (D=2..6)
    for wexp, wman in cases:
        if wman not in SUPPORTED_WMAN:
            continue
        fmt = ZkfFormat(wexp, wman)
        n = 1 << fmt.wfull
        exhaustive = n <= (1 << 22)
        inputs = list(range(n)) if exhaustive else \
            [int(x) for x in np.random.default_rng().integers(0, n, RANDOM_CHECK_SAMPLES)]
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
