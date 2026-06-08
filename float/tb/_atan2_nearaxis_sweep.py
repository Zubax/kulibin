#!/usr/bin/env python3
"""DISCOVERY-ONLY targeted dense sweep for zkf_atan2 near-axis / bypass-seam / diagonal faithful rounding.

Mirrors the log2 near-1 methodology: instead of random sampling (which can never hit the extreme corner where the
result -> 0 and its ULP -> 0 faster than the fixed working precision), it DENSELY / exhaustively enumerates the
hard-by-construction inputs:

  R1 theta->0 (+x axis, PRIORITY): smallest |y| magnitudes (densest fracs of the smallest exponents) with x>0 across
     a wide range of x exponents; both signs of y (theta->0+ and theta->0-).
  R2 bypass seam: sweep shift_dn = e_x - e_y densely on BOTH sides of the bypass cutoff (tiny_shift), with dense
     fracs, x>0 (the residual-vs-bypass seam).
  R3 |y|==|x| diagonal / octant edge: theta near 1/8, 3/8 (and the swapped near-1/8 from the other side).
  R4 theta near 0.25 / 0.5 / 0.75 (normal magnitude, lower priority): x~0 (vertical), x<0 (negative axis).
  R5 mag near rounding/binade boundaries: y much smaller than x so mag ~= |x| but with a tiny correction; dense fracs
     of x at several binades, with a spread of much-smaller y.

Uses the SAME oracle (atan2_true, mpmath mp.prec=400) and the SAME ULP metric as zkf_trig.py::_check_atan2.
Read-only: computes and reports, edits nothing.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TB = REPO / "tb"
sys.path.insert(0, str(TB))

import mpmath as mp  # noqa: E402

mp.mp.prec = 400  # match the oracle precision used by zkf_trig.py

from zkf_model import (  # noqa: E402
    ZkfFormat, atan2_reference, atan2_true, decode, normal, zero, significand, canonicalize_special,
)
import zkf_trig_tables as TBL  # noqa: E402

# (WEXP, WMAN) cases. WMAN list is the full SUPPORTED_WMAN; WEXP mirrors zkf_trig.py::_check_atan2 where given,
# otherwise a representative moderate WEXP that yields a wide-but-tractable exponent dynamic range.
CASES = [
    (5, 11), (6, 16), (6, 18), (8, 24), (8, 27), (8, 32), (8, 36), (8, 48), (8, 53),
]


def ulp_diff(fmt: ZkfFormat, a_bits: int, b_bits: int) -> int:
    """Same ULP metric as zkf_trig.py::_ulp_diff / _ordered_index."""
    if a_bits == b_bits:
        return 0

    def idx(bits: int) -> int:
        bits = canonicalize_special(fmt, bits)
        sign = (bits >> fmt.sign_shift) & 1
        mag = bits & ((1 << fmt.sign_shift) - 1)
        return -mag if sign else mag

    return abs(idx(a_bits) - idx(b_bits))


class Acc:
    """Per-region worst-ULP accumulator with first-violation capture and a few worst exemplars."""

    def __init__(self) -> None:
        self.worst_t = 0
        self.worst_m = 0
        self.n = 0
        self.viol = []   # list of (yb, xb, dt, dm, tr, tt, mr, mt)
        self.worst_t_ex = None
        self.worst_m_ex = None

    def add(self, fmt: ZkfFormat, yb: int, xb: int) -> None:
        self.n += 1
        tr, mr = atan2_reference(fmt, yb, xb)
        tt, mt = atan2_true(fmt, yb, xb)
        dt = ulp_diff(fmt, tr, tt)
        dm = ulp_diff(fmt, mr, mt)
        if dt > self.worst_t:
            self.worst_t = dt
            self.worst_t_ex = (yb, xb, dt, tr, tt)
        if dm > self.worst_m:
            self.worst_m = dm
            self.worst_m_ex = (yb, xb, dm, mr, mt)
        if dt > 1 or dm > 1:
            if len(self.viol) < 12:
                self.viol.append((yb, xb, dt, dm, tr, tt, mr, mt))


def fracs_dense(fmt: ZkfFormat, k: int = 64) -> list[int]:
    """Dense fraction set: low/high runs (the binade edges where the rounding direction flips), the midpoint
    neighborhood, and an even spread of ~k across the whole field. Hard-capped at ~4*k+ entries even for tiny formats
    so the multi-loop cross-products stay tractable; density is concentrated where faithful rounding is fragile (the
    extremes), which is exactly the log2-near-1 lesson."""
    nf = 1 << fmt.wfrac
    fm = fmt.frac_mask
    if nf <= (4 * k):
        return list(range(nf))
    out = set()
    # low and high runs (the binade edges, where rounding direction flips), plus the midpoint neighborhood
    for d in range(k):
        out.add(d)
        out.add(fm - d)
        out.add(((nf >> 1) + d) & fm)
        out.add(((nf >> 1) - 1 - d) & fm)
    # even spread across the whole field
    step = max(1, nf // k)
    out.update(range(0, nf, step))
    return sorted(out)


def small_exps(fmt: ZkfFormat, k: int = 12) -> list[int]:
    """The smallest biased exponents (densest small-magnitude binades) plus a couple just above."""
    hi = min(fmt.exp_inf, k + 2)
    return list(range(1, hi))


def x_exps_spread(fmt: ZkfFormat, k: int = 24) -> list[int]:
    """A spread of x exponents from min to max finite (drives theta over its whole small->moderate range)."""
    lo, hi = 1, fmt.exp_max_finite
    pts = sorted(set(
        [lo, lo + 1, lo + 2, fmt.bias - 1, fmt.bias, fmt.bias + 1, hi - 1, hi]
        + list(range(lo, hi + 1, max(1, (hi - lo) // k)))
    ))
    return [e for e in pts if lo <= e <= hi]


# --------------------------------------------------------------------------------------------------
# Region sweeps
# --------------------------------------------------------------------------------------------------
def sweep_R1_theta_to_zero(fmt: ZkfFormat, acc: Acc) -> None:
    """PRIORITY: theta -> 0 on the +x axis. Smallest |y| binades (dense fracs) x>0 across many x exponents, both y signs.
    This is the construction that makes theta's ULP shrink toward the working-precision floor.

    Density is placed where the log2-near-1 defect lived: the SMALLEST result magnitudes. So |y| is pinned to the few
    smallest exponents with DENSE fracs, while x sweeps a spread of exponents (each x binade shifts theta down by one
    octave, walking it through the smallest-representable / flush region) at a couple of fracs. The smallest-theta corner
    is x at the LARGEST exponent with the smallest |y|."""
    yexps = small_exps(fmt, 4)                         # the 5 smallest |y| binades (theta floor)
    yfracs = fracs_dense(fmt, 96)
    xexps = x_exps_spread(fmt, 28)
    xfracs = [0, fmt.frac_mask]                        # binade bottom and top of x
    for sy in (0, 1):
        for ye in yexps:
            for yf in yfracs:
                yb = normal(fmt, sy, ye, yf)
                for xe in xexps:
                    for xf in xfracs:
                        xb = normal(fmt, 0, xe, xf)   # x > 0 (the +x axis)
                        acc.add(fmt, yb, xb)


def sweep_R2_bypass_seam(fmt: ZkfFormat, acc: Acc) -> None:
    """The small-ratio bypass cutoff. Bypass fires (x>0, not swapped) iff shift_dn = e_x - e_y > tiny_shift, where
    tiny_shift = zf - wman - GUARD_DIV. Sweep shift_dn densely on BOTH sides of tiny_shift, with dense fracs on both
    operands so the divide truncation/sticky and the residual-vs-bypass handoff are exercised at the seam."""
    spec = TBL.SPECS[fmt.wman]
    tiny_shift = spec["zf"] - fmt.wman - TBL.GUARD_DIV
    # Anchor y near the low end of the exponent range so x can be pushed up to reach large shift_dn without overflow.
    yfracs = fracs_dense(fmt, 64)
    xfracs = fracs_dense(fmt, 16)                           # x's own fraction is secondary; the seam is in shift_dn
    # Choose a y exponent that leaves room above for the largest desired shift_dn.
    deltas = list(range(tiny_shift - 6, tiny_shift + 7))   # both sides of the cutoff, +-6
    deltas = [d for d in deltas if d >= 0]
    for sy in (0, 1):
        # pick a y exponent comfortably above min so theta stays representable, yet leaves headroom above
        for ye in (max(1, fmt.bias - 2), 2):
            for d in deltas:
                xe = ye + d
                if not (1 <= xe <= fmt.exp_max_finite):
                    continue
                for yf in yfracs:
                    yb = normal(fmt, sy, ye, yf)
                    for xf in xfracs:
                        xb = normal(fmt, 0, xe, xf)
                        acc.add(fmt, yb, xb)


def sweep_R3_diagonal(fmt: ZkfFormat, acc: Acc) -> None:
    """|y| ~= |x| octant edge: theta near 1/8 (x>0) and 3/8 (x<0). Dense fracs around equality, both exponent-equal and
    one-binade-apart, all sign combos."""
    fm = fmt.frac_mask
    near = sorted(set([0, 1, 2, 3, fm, fm - 1, fm - 2, (1 << (fmt.wfrac - 1))] + list(range(0, 1 << fmt.wfrac,
                  max(1, (1 << fmt.wfrac) // 48)))))
    e = fmt.bias
    for sx in (0, 1):
        for sy in (0, 1):
            for xf in near:
                xb = normal(fmt, sx, e, xf)
                for yf in near:
                    # exponent-equal (|y|~|x|) and one binade apart on each side
                    acc.add(fmt, normal(fmt, sy, e, yf), xb)
                    if e + 1 <= fmt.exp_max_finite:
                        acc.add(fmt, normal(fmt, sy, e + 1, yf), xb)
                    if e - 1 >= 1:
                        acc.add(fmt, normal(fmt, sy, e - 1, yf), xb)


def sweep_R4_quarter_half(fmt: ZkfFormat, acc: Acc) -> None:
    """theta near 1/4 (x~0, vertical), 1/2 (x<0, negative axis), 3/4 (x<0, y<0). Smallest |x| with larger |y| (near
    1/4), and smallest |y| with x<0 (near 1/2 / 3/4). Dense fracs of the small operand."""
    smallfr = fracs_dense(fmt, 80)          # dense fracs of the SMALL operand (drives the near-axis result)
    bigfr = [0, fmt.frac_mask, 1 << (fmt.wfrac - 1)]   # the large operand's fraction is secondary
    # near 1/4: |x| << |y|, x>0; both y signs (1/4 and -1/4). x is the small operand (dense), y the large.
    for sy in (0, 1):
        for xe in small_exps(fmt, 4):
            ye = min(fmt.exp_max_finite, xe + (TBL.SPECS[fmt.wman]["zf"] - fmt.wman))
            for yf in bigfr:
                yb = normal(fmt, sy, ye, yf)
                for xf in smallfr:
                    acc.add(fmt, yb, normal(fmt, 0, xe, xf))
    # near 1/2 and 3/4: |y| << |x|, x<0; both y signs (theta -> +1/2 / -1/2 i.e. 3/4 turn). y is the small operand.
    for sy in (0, 1):
        for ye in small_exps(fmt, 4):
            xe = min(fmt.exp_max_finite, ye + (TBL.SPECS[fmt.wman]["zf"] - fmt.wman))
            for xf in bigfr:
                xb = normal(fmt, 1, xe, xf)   # x < 0
                for yf in smallfr:
                    acc.add(fmt, normal(fmt, sy, ye, yf), xb)


def sweep_R5_mag_binade(fmt: ZkfFormat, acc: Acc) -> None:
    """mag = hypot near rounding/binade boundaries: y much smaller than x so mag ~= |x| with a tiny correction that can
    tip the round. Dense fracs of |x| (esp. the binade top, all-ones, where hypot's tiny add can carry), with a spread
    of much-smaller |y|."""
    xfracs = fracs_dense(fmt, 96)            # dense |x| fracs, esp. the binade top where hypot's tiny add can carry
    yfracs = [0, fmt.frac_mask, 1, 1 << (fmt.wfrac - 1)]   # the tiny correction term; its detail is secondary
    for xe in (max(1, fmt.bias - 1), fmt.bias, fmt.bias + 1, fmt.exp_max_finite):
        if not (1 <= xe <= fmt.exp_max_finite):
            continue
        for sx in (0, 1):
            for xf in xfracs:
                xb = normal(fmt, sx, xe, xf)
                # y far smaller (so mag~|x|) at a spread of much-smaller exponents (the correction shrinks each octave)
                for dye in (fmt.wfrac // 2, fmt.wfrac, fmt.wfrac + 2, fmt.wfrac * 2, fmt.wfrac * 2 + 4):
                    ye = xe - dye
                    if ye < 1:
                        continue
                    for sy in (0, 1):
                        for yf in yfracs:
                            acc.add(fmt, normal(fmt, sy, ye, yf), xb)


REGIONS = [
    ("R1 theta->0 (+x axis)  [PRIORITY]", sweep_R1_theta_to_zero),
    ("R2 bypass seam (e_x-e_y ~ cutoff)", sweep_R2_bypass_seam),
    ("R3 diagonal |y|=|x| (theta~1/8,3/8)", sweep_R3_diagonal),
    ("R4 theta~1/4,1/2,3/4", sweep_R4_quarter_half),
    ("R5 mag binade (y<<x, mag~|x|)", sweep_R5_mag_binade),
]


def fmt_input(fmt: ZkfFormat, yb: int, xb: int) -> str:
    dy = decode(fmt, yb)
    dx = decode(fmt, xb)
    return (f"y=({'-' if dy.sign else '+'}e{dy.exp - fmt.bias},f{dy.frac:#x}) "
            f"x=({'-' if dx.sign else '+'}e{dx.exp - fmt.bias},f{dx.frac:#x}) "
            f"[y={hex(yb)} x={hex(xb)}]")


def main() -> None:
    print("=" * 110)
    print("zkf_atan2 DENSE near-axis / bypass-seam / diagonal sweep  (oracle: mpmath mp.prec=400, ULP metric per "
          "_check_atan2)")
    print("=" * 110)
    grand_worst_t = 0
    grand_worst_m = 0
    any_viol = False
    # table rows: (wexp, wman, region, n, worst_t, worst_m)
    rows = []
    for wexp, wman in CASES:
        if wman not in TBL.SPECS:
            continue
        fmt = ZkfFormat(wexp, wman)
        spec = TBL.SPECS[wman]
        tiny_shift = spec["zf"] - wman - TBL.GUARD_DIV
        print(f"\n### WEXP={wexp} WMAN={wman}  (xf={spec['xf']} zf={spec['zf']} n_atan2={spec['n_atan2']} "
              f"bypass cutoff tiny_shift={tiny_shift})")
        for name, fn in REGIONS:
            acc = Acc()
            fn(fmt, acc)
            grand_worst_t = max(grand_worst_t, acc.worst_t)
            grand_worst_m = max(grand_worst_m, acc.worst_m)
            flag = "  <-- VIOLATION" if (acc.worst_t > 1 or acc.worst_m > 1) else ""
            print(f"  {name:<40} n={acc.n:>8}  theta_ulp={acc.worst_t}  mag_ulp={acc.worst_m}{flag}")
            rows.append((wexp, wman, name, acc.n, acc.worst_t, acc.worst_m))
            if acc.viol:
                any_viol = True
                for (yb, xb, dt, dm, tr, tt, mr, mt) in acc.viol[:6]:
                    print(f"      VIOL dt={dt} dm={dm}  {fmt_input(fmt, yb, xb)}")
                    print(f"           theta ref={hex(tr)} true={hex(tt)} | mag ref={hex(mr)} true={hex(mt)}")
            else:
                # show the worst-ULP exemplar so the report has the binding input even when clean
                if acc.worst_t_ex and acc.worst_t >= 1:
                    yb, xb, d, tr, tt = acc.worst_t_ex
                    print(f"      worst-theta exemplar dt={d}: {fmt_input(fmt, yb, xb)} "
                          f"ref={hex(tr)} true={hex(tt)}")
                if acc.worst_m_ex and acc.worst_m >= 1:
                    yb, xb, d, mr, mt = acc.worst_m_ex
                    print(f"      worst-mag   exemplar dm={d}: {fmt_input(fmt, yb, xb)} "
                          f"ref={hex(mr)} true={hex(mt)}")

    print("\n" + "=" * 110)
    print("PER-REGION PER-WMAN WORST ULP TABLE")
    print("=" * 110)
    print(f"{'WEXP':>4} {'WMAN':>4}  {'region':<40} {'count':>9} {'theta_ULP':>9} {'mag_ULP':>8}")
    for (wexp, wman, name, n, wt, wm) in rows:
        print(f"{wexp:>4} {wman:>4}  {name:<40} {n:>9} {wt:>9} {wm:>8}")
    print("=" * 110)
    print(f"GRAND WORST: theta_ulp={grand_worst_t}  mag_ulp={grand_worst_m}  "
          f"{'>>> VIOLATIONS FOUND <<<' if any_viol else 'CLEAN (all <= 1 ULP)'}")


if __name__ == "__main__":
    main()
