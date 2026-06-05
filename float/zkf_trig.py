#!/usr/bin/env python3
"""
Constant generator for the ZKF CORDIC trigonometric operators: zkf_sincos, zkf_atan2.

The phase ``x`` is measured in turns, so ``sin = sin(2*pi*x)`` and ``cos = cos(2*pi*x)``. The streamed module reduces
``x`` mod 1 to a fixed-point fraction ``frac(x) in [0,1)``, splits it into the 2-bit ``quadrant`` (top two fractional
bits) and a quadrant-local coordinate ``t in [0,1)`` (local angle ``theta = (pi/2)*t``), folds the half-quadrant
symmetry to bring the angle into ``[0, pi/4]`` (one octant), runs a fixed-point CORDIC rotation to get
``(cos theta', sin theta')``, then unmaps the octant/quadrant and packs the two magnitudes as ZKF floats.

Why CORDIC? Faithful sin/cos needs relative accuracy near each zero; the only multiply-free way to get that across the
whole range is CORDIC (the rotation is exact up to the iteration count, no small-coefficient cancellation). It uses no
multipliers in the iteration array (adds and shifts only) -- the inverse-gain is folded into the seed.
Critically the SAME engine, run in *vectoring* mode, computes ``atan2`` (and the vector magnitude) from a vector,
reusing the arctan LUT (stored here in *turns* so atan2's result is already in turns), the add/shift datapath,
the iteration count, and the quadrant pre/post-processing. The engine ``hdl/_zkf_cordic.v`` is therefore generic and
mode-parameterized; this file only generates the per-WMAN constants.

Angle units: The arctan LUT is stored in turns: ``L[i] = atan(2**-i) / (2*pi)`` at scale ``2**-ZF``. With the
octant-reduced coordinate ``t'`` (scale ``2**-WT``) the local angle in turns is ``theta'/(2*pi) = t'/4``, so the CORDIC
angle accumulator seed is simply ``z0 = t'`` read at scale ``2**-(WT+2) == 2**-ZF`` (no conversion multiply).

Tiny / near-boundary angles: for ``theta'`` below the CORDIC's smallest resolvable step the rotation cannot place the
small sine, so a small-angle path returns ``sin ~= 2*pi*x`` (one multiply against a generated high-precision ``2*pi``)
and ``cos = +1``; ``GUARD_FF(WMAN)`` places that boundary where the linear small-angle approximation already holds to
<= 1 ULP. After the octant fold ``cos`` is never small (theta' <= pi/4 => cos >= cos(pi/4)), so only sin needs it.

``--emit`` writes, per supported WMAN, ``hdl/_tables/_zkf_cordic_m<WMAN>.v`` (the LUT + seed + widths bound to the
generic engine) plus the Python data ``tb/zkf_trig_tables.py`` the bit-exact reference model imports; ``--check``
verifies both outputs and the quadrant against an ``mpmath`` ground truth (faithful rounding, <= 1 ULP).
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from math import ceil, log2
from pathlib import Path
from textwrap import dedent

import mpmath as mp

mp.mp.prec = 400  # generous working precision for the gain/LUT constants and ground-truth rounding

REPO = Path(__file__).resolve().parent
HDL = REPO / "hdl"
TABLES = HDL / "_tables"
TB = REPO / "tb"

FUNC = "sincos"

# MIXED CORDIC: run only K ~ WMAN/2 rotation iterations, then finish the small residual angle with ONE linear rotation
# (the "Taylor / final-rotation" termination): cos = x_K - y_K*phi, sin = y_K + x_K*phi, phi = residual (radians). The
# linear step's dropped phi^2/2 term is < 1 ULP once the residual <= ~2**-(WMAN/2), i.e. after ~WMAN/2 iterations, so
# the pipeline is K ~ WMAN/2 stages instead of ~1.5*WMAN -- the LUT/FF win, traded for the two correction multiplies.
# (The correction only fixes the ANGLE residual; the iteration array's own truncation still limits the small sines the
# CORDIC must place, so the datapath keeps ~1.5*WMAN fractional bits and the small-angle linear bypass below TSA stays.)
GUARD_XY = 8     # x/y fractional bits past 1.5*WMAN (round/sticky + iteration-rounding headroom)
# Iterations before the linear termination: K = (WMAN+1)//2 + GUARD_ITER. GUARD_ITER pushes the residual a couple bits
# below the 2**-(WMAN/2) the linear step needs (and drives theta' up to pi/4 down to it), covering iteration rounding.
GUARD_ITER = 5
# Angle accumulator integer headroom above the ZF fractional bits (z stays within +-(1/4 turn) through the rotation).
GUARD_Z = 3
# Angle fractional precision past the coordinate's own (WT+2) turns bits: the rotation sums K rounded LUT entries, each
# quantized to 2**-ZF, accumulating ~K*2**-ZF of angle error, and the residual feeds the correction multiply, so it
# must keep the full small-angle precision. The seed is z0 = t' << GUARD_ZF (coordinate shifted into the finer scale).
GUARD_ZF = 6
# atan2 residual-divide guard: extra quotient fractional bits kept below the WMAN significand so the linear
# divide-termination (atan(y_K/x_K) ~= y_K/x_K) and the small-ratio bypass round to <= 1 ULP. Paired with GUARD_XY,
# this mirrors the sincos correction-operand budget; consumed by the atan2 reference model and zkf_atan2.v.
GUARD_DIV = 8

WMAN_MIN, WMAN_MAX = 11, 53
SUPPORTED_WMAN = [11, 16, 18, 24, 27, 32, 36, 48, 53]


def guard_ff(wman: int) -> int:
    # Reduced-fraction guard placing the small-angle handoff e_b = -(GUARD_FF+2) where the linear small-angle path
    # holds <= 1 ULP (binding term: |1 - cos(2*pi*2**e_b)| ~= (2*pi*2**e_b)**2/2 <= 2**-WMAN -> GUARD_FF >= WMAN//2 + 2).
    # Floored at 12 so the common small formats keep a modest reduced fraction. Mirrored in hdl/zkf_sincos.v.
    return max(12, wman // 2 + 2)


def ff_bits(wman: int) -> int:
    """Reduced fraction width FF: frac(x) at scale 2**-FF; top 2 bits = quadrant, low FF-2 = t."""
    return wman + guard_ff(wman)


def wt_bits(wman: int) -> int:
    """Quadrant-local coordinate width WT = FF - 2 (t in [0,1) at scale 2**-WT)."""
    return ff_bits(wman) - 2


def n_iters(wman: int) -> int:
    """K: rotation iterations before the linear termination (see the GUARD_ITER comment)."""
    return (wman + 1) // 2 + GUARD_ITER


def tsa_bits(wman: int) -> int:
    """Small-angle handoff: octant-local coordinate t' below 2**TSA_BITS takes the linear small-angle bypass
    (sin = 2*pi*theta'_turns, cos = 1) instead of the CORDIC. Bound by the cos=1 rounding limit theta'(rad) <
    2**-(WMAN/2): t' < 2**(ZF - ceil(WMAN/2) - log2(2*pi)), so TSA_BITS = (WT+2) - ceil(WMAN/2) - 3."""
    return (wt_bits(wman) + 2) - ((wman + 1) // 2) - 3


def cordic_module(wman: int) -> str:
    return f"_zkf_cordic_m{wman}"


@dataclass
class Spec:
    wman: int
    n: int                 # CORDIC iterations
    xf: int                # x/y fractional bits (scale 2**-xf)
    xw: int                # x/y signed width (1 sign + 1 integer + xf)
    wt: int                # quadrant-local coordinate width (FF - 2); angle in turns is t'/4 at scale 2**-(WT+2)
    zf: int                # angle accumulator fractional bits (scale 2**-zf) = WT + 2 + GUARD_ZF (finer than WT+2)
    zw: int                # angle signed width
    kinv: int              # round(1/gain * 2**xf), gain = prod sqrt(1+2**-2i)
    tsa: int = 0           # small-angle handoff: t' < tsa uses the linear path (TSA_BITS = log2)
    lut: list = field(default_factory=list)  # L[i] = round(atan(2**-i)/(2*pi) * 2**zf), i = 0..n-1
    c2: int = 0            # small-angle 2*pi constant scale (== xf)
    const2pi: int = 0      # round(2*pi * 2**c2), the high-precision small-angle constant
    inv_tau: int = 0       # round(2**xf / (2*pi)): reciprocal-tau for the atan2 residual/bypass turns scaling


def cordic_gain(n: int):
    g = mp.mpf(1)
    for i in range(n):
        g *= mp.sqrt(1 + mp.mpf(2) ** (-2 * i))
    return g


def choose_spec(wman: int) -> Spec:
    """All-closed-form: the CORDIC depth and widths are functions of WMAN (so the pipeline depth is too). The arctan
    LUT is in turns and the inverse gain folds into the x seed; --check validates the resulting faithfulness."""
    if not (WMAN_MIN <= wman <= WMAN_MAX):
        raise ValueError(f"Bad {wman=}")
    n = n_iters(wman)
    xf = ceil(3 * wman / 2) + GUARD_XY
    zf = wt_bits(wman) + 2 + GUARD_ZF
    xw = xf + 2
    zw = zf + GUARD_Z
    kinv = int(mp.nint((1 / cordic_gain(n)) * (mp.mpf(2) ** xf)))
    lut = [int(mp.nint(mp.atan(mp.mpf(2) ** (-i)) / (2 * mp.pi) * (mp.mpf(2) ** zf))) for i in range(n)]
    const2pi = int(mp.nint(2 * mp.pi * (mp.mpf(2) ** xf)))
    inv_tau = int(mp.nint((mp.mpf(1) / (2 * mp.pi)) * (mp.mpf(2) ** xf)))
    return Spec(wman, n, xf, xw, wt_bits(wman), zf, zw, kinv, 1 << tsa_bits(wman), lut, xf, const2pi, inv_tau)


def generate_all() -> dict[int, Spec]:
    return {wman: choose_spec(wman) for wman in SUPPORTED_WMAN}


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


def _emit_consts(s: Spec) -> str:
    """
    Per-WMAN CORDIC constants bound to the generic engine hdl/_zkf_cordic.v. The MODE parameter is passed straight
    through (ROTATION for zkf_sincos, VECTORING for zkf_atan2) so all operators reuse the same LUT, gain seed, widths,
    and engine -- only the mode differs.
    """
    mod = cordic_module(s.wman)
    cwb = s.const2pi.bit_length()                        # == XF + 3
    itwb = s.inv_tau.bit_length()                        # == XF - 2 (1/(2*pi) < 1/4)
    w = _Writer()
    w("/// GENERATED by zkf_trig.py -- DO NOT EDIT.")
    w(f"/// Per-WMAN CORDIC constants (WMAN={s.wman}): arctan(2^-i)/2pi LUT in turns, inverse-gain seed, widths.")
    w("/// Binds the generic engine _zkf_cordic; MODE selects rotation (sin/cos) vs vectoring (atan2). Also exposes the")
    w("/// 2*pi constant for the sin/cos small-angle path (a constant output; atan2 leaves it unconnected).")
    w("")
    w("`default_nettype none")
    w("")
    w(f"module {mod} #(")
    w.push()
    w("parameter integer MODE      = 0,")
    w("parameter integer UNROLL100 = 100,")
    w("parameter integer PARALLEL  = (UNROLL100 < 100) ? 1 : 0,")
    w("parameter integer WSB       = 1")
    w.pop()
    w(") (")
    w.push()
    w(f"""
        input  wire                clk,
        input  wire                rst,
        input  wire                start,
        input  wire      [WSB-1:0] sb_in,
        input  wire signed [{s.xw - 1:3}:0] x0,
        input  wire signed [{s.xw - 1:3}:0] y0,
        input  wire signed [{s.zw - 1:3}:0] z0,
        output wire                busy,
        output wire                done,
        output wire                z_done,
        output wire      [WSB-1:0] sb_out,
        output wire signed [{s.xw - 1:3}:0] xn,
        output wire signed [{s.xw - 1:3}:0] yn,
        output wire signed [{s.zw - 1:3}:0] zn,
        output wire        [{cwb - 1:3}:0] const2pi,   // round(2*pi * 2**XF), CWB = XF + 3 bits (sin/cos small angle)
        output wire        [{itwb - 1:3}:0] inv_tau,    // round(2**XF / (2*pi)), XF-2 bits (atan2 turns scaling)
        output wire        [{s.xw - 1:3}:0] kinv        // round(2**XF / gain), inverse CORDIC-gain (atan2 magnitude)
    """)
    w.pop()
    w(");")
    w.push()
    w(f"localparam integer N    = {s.n};   // iterations (folded over the cycles selected by UNROLL100)")
    w(f"localparam integer WX   = {s.xw};")
    w(f"localparam integer WZ   = {s.zw};")
    w(f"localparam integer XF   = {s.xf};   // x/y fractional scale")
    w(f"localparam integer ZF   = {s.zf};   // angle (turns) fractional scale == WT + 2 + GUARD_ZF")
    w(f"localparam integer CWB  = {cwb};")
    w(f"localparam signed [WX-1:0] KINV = {s.xw}'sd{s.kinv};   // round(1/gain * 2**XF) (== 2**XF/gain)")
    w("")
    w(f"assign const2pi = {cwb}'d{s.const2pi};")
    w(f"assign inv_tau  = {itwb}'d{s.inv_tau};")
    w("assign kinv     = KINV[WX-1:0];")
    w("")
    w("// arctan(2^-i)/(2*pi) in turns, scale 2**-ZF, packed L[0] in the low WZ bits.")
    w("wire [N*WZ-1:0] LUT = {")
    w.push()
    # high index first in the concatenation literal (MSBs), L[0] last (LSBs)
    for i in reversed(range(s.n)):
        sep = "" if i == 0 else ","
        w(f"{s.zw}'d{s.lut[i]}{sep}   // atan(2^-{i})/2pi")
    w.pop()
    w("};")
    w("")
    w("""
        // Rotation mode (sin/cos) seeds the vector with the gain-compensated (1/gain, 0) so (xn, yn) = (cos z0, sin z0);
        // the x0/y0 inputs are then ignored. Vectoring mode (atan2) uses the x0/y0 vector inputs as given.
        wire signed [WX-1:0] seed_x = (MODE == 0) ? KINV       : x0;
        wire signed [WX-1:0] seed_y = (MODE == 0) ? {WX{1'b0}} : y0;
        _zkf_cordic #(
            .N(N), .UNROLL100(UNROLL100), .PARALLEL(PARALLEL), .WX(WX), .WZ(WZ), .MODE(MODE), .WSB(WSB)
        ) u_cordic (
            .clk(clk), .rst(rst), .start(start), .sb_in(sb_in),
            .x0(seed_x), .y0(seed_y), .z0(z0), .lut(LUT),
            .busy(busy), .done(done), .z_done(z_done), .sb_out(sb_out), .xn(xn), .yn(yn), .zn(zn)
        );
    """)
    w.pop()
    w("endmodule")
    w("")
    w("`default_nettype wire")
    return w.render()


def _emit_python(all_specs: dict[int, Spec]) -> str:
    w = _Writer()
    w("# GENERATED by zkf_trig.py -- DO NOT EDIT.")
    w('"""Bit-exact CORDIC constants for zkf_sincos (and the shared atan2 engine), consumed by zkf_model.py."""')
    w("")
    w("SPECS = {")
    w.push()
    for wman in sorted(all_specs):
        s = all_specs[wman]
        w(f"{wman}: dict(")
        w.push()
        w(f"n={s.n}, xf={s.xf}, xw={s.xw}, wt={s.wt}, zf={s.zf}, zw={s.zw}, kinv={s.kinv}, tsa={s.tsa}, "
          f"c2={s.c2}, const2pi={s.const2pi}, inv_tau={s.inv_tau},")
        w(f"lut={s.lut!r},")
        w.pop()
        w("),")
    w.pop()
    w("}")
    w("")
    w(f"GUARD_XY = {GUARD_XY}")
    w(f"GUARD_ITER = {GUARD_ITER}")
    w(f"GUARD_DIV = {GUARD_DIV}")
    w("# FF (reduced-fraction width) = WMAN + max(12, WMAN//2 + 2); WT = FF - 2; ZF = WT + 2.")
    w("")
    w("""
        def get_spec(wman):
            try:
                return SPECS[wman]
            except KeyError:
                raise KeyError(f'no sincos CORDIC spec for WMAN={wman}; run zkf_trig.py --emit')
    """)
    return w.render()


def emit(all_specs: dict[int, Spec]) -> None:
    TABLES.mkdir(parents=True, exist_ok=True)
    for wman, s in sorted(all_specs.items()):
        path = TABLES / f"{cordic_module(wman)}.v"
        path.write_text(_emit_consts(s))
        print(f"wrote {path.relative_to(REPO)}")
    path = TB / "zkf_trig_tables.py"
    path.write_text(_emit_python(all_specs))
    print(f"wrote {path.relative_to(REPO)}")


# --------------------------------------------------------------------------------------------------
# Reporting and accuracy check
# --------------------------------------------------------------------------------------------------
def _report(all_specs: dict[int, Spec]) -> None:
    print(f"{'WMAN':>4} {'N':>4} {'XF':>4} {'WX':>4} {'ZF':>4} {'WZ':>4} {'WT':>4} {'lut_bits':>8}")
    for wman, s in sorted(all_specs.items()):
        lut_bits = s.n * s.zw
        print(f"{wman:>4} {s.n:>4} {s.xf:>4} {s.xw:>4} {s.zf:>4} {s.zw:>4} {s.wt:>4} {lut_bits:>8}")


def _check(all_specs: dict[int, Spec]) -> None:
    """End-to-end faithful-rounding check vs mpmath via the bit-exact model. Requires tb/ on sys.path."""
    import sys
    sys.path.insert(0, str(TB))
    import importlib
    import zkf_model
    importlib.reload(zkf_model)
    from zkf_model import ZkfFormat, sincos_reference, sincos_true

    print("end-to-end faithful-rounding check (model vs mpmath):")
    cases = [(5, 11), (6, 16), (8, 24), (8, 36), (8, 48), (8, 53), (11, 53)]
    worst_overall = 0
    for wexp, wman in cases:
        if wman not in SUPPORTED_WMAN:
            continue
        fmt = ZkfFormat(wexp, wman)
        n = 1 << fmt.wfull
        exhaustive = n <= (1 << 22)
        inputs = list(range(n)) if exhaustive else _stratified_inputs(fmt)
        worst_sin = worst_cos = nq = 0
        bad = None
        for b in inputs:
            sin_r, cos_r, q_r = sincos_reference(fmt, b)
            sin_t, cos_t, q_t = sincos_true(fmt, b)
            ds, dc = _ulp_diff(fmt, sin_r, sin_t), _ulp_diff(fmt, cos_r, cos_t)
            if (ds > 1 or dc > 1 or q_r != q_t) and bad is None:
                bad = (b, ds, dc, q_r, q_t)
            worst_sin, worst_cos = max(worst_sin, ds), max(worst_cos, dc)
            nq += int(q_r != q_t)
        tag = "exhaustive" if exhaustive else f"sampled({len(inputs)})"
        ok = worst_sin <= 1 and worst_cos <= 1 and nq == 0
        worst_overall = max(worst_overall, worst_sin, worst_cos)
        print(f"  {'OK ' if ok else 'BAD'} {wexp}/{wman:<3} sin_ulp={worst_sin} cos_ulp={worst_cos} "
              f"quad_mismatch={nq} ({tag})")
        assert ok, f"{wexp}/{wman}: sin_ulp={worst_sin} cos_ulp={worst_cos} quad_mismatch={nq} first_bad={bad}"


def _stratified_inputs(fmt) -> list[int]:
    import numpy as np
    from zkf_model import pack_bits
    rng = np.random.default_rng(0x5C05)

    def rand_bits() -> int:
        v = 0
        for _ in range((fmt.wfull + 31) // 32):
            v = (v << 32) | int(rng.integers(0, 1 << 32))
        return v & ((1 << fmt.wfull) - 1)

    out = [rand_bits() for _ in range(100_000)]
    quarter_fracs = [0, 1, fmt.frac_mask, (1 << (fmt.wfrac - 1)) | 1]
    for exp in range(1, fmt.exp_inf):
        for sign in (0, 1):
            for _ in range(6):
                out.append(pack_bits(fmt, sign, exp, int(rng.integers(0, 1 << fmt.wfrac))))
            for fr in quarter_fracs:
                out.append(pack_bits(fmt, sign, exp, fr))
    return out


def _ulp_diff(fmt, a_bits: int, b_bits: int) -> int:
    return 0 if a_bits == b_bits else abs(_ordered_index(fmt, a_bits) - _ordered_index(fmt, b_bits))


def _ordered_index(fmt, bits: int) -> int:
    import zkf_model
    bits = zkf_model.canonicalize_special(fmt, bits)
    sign = (bits >> fmt.sign_shift) & 1
    mag = bits & ((1 << fmt.sign_shift) - 1)
    return -mag if sign else mag


def _atan2_pairs(fmt) -> list[tuple[int, int]]:
    """Thorough stratified (y, x) pairs for the atan2 faithful-rounding check. True joint-exhaustive is infeasible (the
    smallest supported format already has WFULL >= 13, i.e. >= 2**26 pairs), so this combines random pairs with two
    full single-operand "fans": every (sign, exponent, frac-sample) of one operand crossed with a few central-binade
    anchors of the other. Because atan2 depends on the exponent DIFFERENCE, the fans cross every small-ratio-bypass
    threshold and octant/quadrant boundary in both diff directions; the diagonals exercise the |y|==|x| octant edge."""
    import numpy as np
    from zkf_model import normal

    rng = np.random.default_rng(0xA7A2)

    def rand_bits() -> int:
        v = 0
        for _ in range((fmt.wfull + 31) // 32):
            v = (v << 32) | int(rng.integers(0, 1 << 32))
        return v & ((1 << fmt.wfull) - 1)

    sgn = 1 << fmt.sign_shift
    specials = [0, sgn, fmt.exp_inf << fmt.wfrac, sgn | (fmt.exp_inf << fmt.wfrac)]
    fracs = [0, 1, fmt.frac_mask, 1 << (fmt.wfrac - 1)]
    anchors = [normal(fmt, s, fmt.bias, fr) for s in (0, 1) for fr in (0, fmt.frac_mask)]

    pairs: set[tuple[int, int]] = set()
    for _ in range(40_000):
        pairs.add((rand_bits(), rand_bits()))
    swept = list(specials)
    for s in (0, 1):
        for e in range(1, fmt.exp_inf):
            for fr in fracs:
                swept.append(normal(fmt, s, e, fr))
    for w in swept:
        for a in anchors:
            pairs.add((w, a))                                # operand swept on the y side, x anchored
            pairs.add((a, w))                                # operand swept on the x side, y anchored
    for s in (0, 1):
        for e in range(1, fmt.exp_inf):
            base = normal(fmt, s, e, 0)
            pairs.add((base, base))                          # |y| == |x| (octant edge)
            pairs.add((base, base ^ sgn))
    return list(pairs)


def _check_atan2(all_specs: dict[int, Spec]) -> None:
    """End-to-end faithful-rounding check for zkf_atan2 (theta and mag) vs mpmath via the bit-exact model."""
    import sys
    sys.path.insert(0, str(TB))
    import importlib
    import zkf_model
    importlib.reload(zkf_model)
    from zkf_model import ZkfFormat, atan2_reference, atan2_true

    print("atan2 end-to-end faithful-rounding check (model vs mpmath):")
    cases = [(5, 11), (6, 18), (8, 24), (8, 36), (8, 48), (8, 53), (11, 53)]
    for wexp, wman in cases:
        if wman not in SUPPORTED_WMAN:
            continue
        fmt = ZkfFormat(wexp, wman)
        pairs = _atan2_pairs(fmt)
        worst_t = worst_m = 0
        bad = None
        for yb, xb in pairs:
            tr, mr = atan2_reference(fmt, yb, xb)
            tt, mt = atan2_true(fmt, yb, xb)
            dt, dm = _ulp_diff(fmt, tr, tt), _ulp_diff(fmt, mr, mt)
            if (dt > 1 or dm > 1) and bad is None:
                bad = (hex(yb), hex(xb), dt, dm)
            worst_t, worst_m = max(worst_t, dt), max(worst_m, dm)
        ok = worst_t <= 1 and worst_m <= 1
        print(f"  {'OK ' if ok else 'BAD'} {wexp}/{wman:<3} theta_ulp={worst_t} mag_ulp={worst_m} "
              f"(sampled({len(pairs)}))")
        assert ok, f"{wexp}/{wman}: theta_ulp={worst_t} mag_ulp={worst_m} first_bad={bad}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--emit", action="store_true", help="write the per-WMAN CORDIC constant cores and Python data")
    ap.add_argument("--check", action="store_true",
                    help="verify sincos AND atan2 accuracy vs mpmath (uses the bit-exact model)")
    ap.add_argument("--report", action="store_true", help="print the chosen CORDIC shapes (iterations, widths, LUT)")
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
        _check_atan2(all_specs)


if __name__ == "__main__":
    main()
