#!/usr/bin/env python3
"""Single source of truth for the float verification matrix.

Every simulation the suite runs is one `Run` here: a module, a simulator (icarus/verilator), a set of
fusesoc parameters, and a tier. The tiers gate selection:

  pr          per-PR set (runs by default; what `make verify-float` exercises)
  deep        full parameter-equivalence-class sweep (correctness on icarus, coverage on verilator)
  properties  algebraic-property tests (test_properties.py) on the add/addsub/mul toplevels
  fast        the smallest-config smoke set

`test_float_matrix.py` parametrizes pytest over `build_matrix()`, tagging each Run with its tier and
simulator as markers; `pytest.ini` deselects deep/properties/fast by default, so the deep work skips
unless explicitly selected (`pytest -m deep`, etc.). This replaces the former Makefile recipe loops and
float/tb/run_extended.sh, which duplicated the same fusesoc-invocation logic in three places.

Running this module directly prints the matrix (counts per tier/sim, or the full list with --list) so it
can be diffed against the suite it replaces.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

SEED = os.environ.get("FLOAT_SEED", "0x9e3779b97f4a7c15")
CORE = "zubax:kulibin:float"

# --- matrix data (formerly the FLOAT_*_MATRIX make variables) -------------------------------------
# pack:     (config, wexp, wman, wexp_unbiased, kind, count)
PACK = [
    ("w2_m4_u4_exhaustive", 2, 4, 4, "exhaustive", 0),
    ("w3_m4_u5_exhaustive", 3, 4, 5, "exhaustive", 0),
    ("w5_m8_u8_random", 5, 8, 8, "random", 768),
    ("w8_m24_u12_random", 8, 24, 12, "random", 2048),
]
# binary:   (config, wexp, wman, kind, count)
BINARY = [
    ("w2_m4_exhaustive", 2, 4, "exhaustive", 0),
    ("w3_m4_exhaustive", 3, 4, "exhaustive", 0),
    ("w3_m5_random", 3, 5, "random", 512),
    ("w4_m6_random", 4, 6, "random", 512),
    ("w5_m11_random", 5, 11, "random", 768),
    ("w6_m18_random", 6, 18, "random", 768),
    ("w7_m17_random", 7, 17, "random", 768),
    ("w8_m24_random", 8, 24, "random", 1024),
    ("w11_m53_random", 11, 53, "random", 384),
]
# fma (ternary a*b+c): exhaustive only at the smallest format (64^3 = 262144 triples); every wider format is
# random because ternary-exhaustive explodes (128^3 = 2M at wfull=7, 512^3 = 134M at wfull=9).
# (config, wexp, wman, kind, count)
FMA = [
    ("w2_m4_exhaustive", 2, 4, "exhaustive", 0),
    ("w3_m4_random", 3, 4, "random", 2048),
    ("w3_m5_random", 3, 5, "random", 768),
    ("w4_m6_random", 4, 6, "random", 768),
    ("w5_m11_random", 5, 11, "random", 768),
    ("w6_m18_random", 6, 18, "random", 1024),
    ("w8_m24_random", 8, 24, "random", 1024),
    ("w8_m36_random", 8, 36, "random", 1024),
    ("w11_m53_random", 11, 53, "random", 512),
    # Small WEXP with large WMAN: the close-cancellation corrected exponent underflows far below the product
    # exponent range, so this guards the sub-path exponent width (the directed w4m30 cancellation witnesses run here).
    ("w4_m30_random", 4, 30, "random", 512),
]
# unary:    (config, wexp, wman, kind, count)
UNARY = [
    ("w2_m4_exhaustive", 2, 4, "exhaustive", 0),
    ("w3_m4_exhaustive", 3, 4, "exhaustive", 0),
    ("w5_m11_random", 5, 11, "random", 512),
    ("w8_m24_random", 8, 24, "random", 1024),
    ("w11_m53_random", 11, 53, "random", 384),
]
# exp2/log2 table+polynomial unary ops; tables exist only for the generator's supported WMAN
# (16,18,24,27,32,36,48,53 -- min is WMAN=16, see SUPPORTED_WMAN/WMAN_MIN in zkf_transcendental.py), so every config
# here must use one of those. The smallest exhaustive format is therefore w<WEXP>_m16.
# (config, wexp, wman, kind, count)
TRANS_EXPLOG = [
    ("w2_m16_exhaustive", 2, 16, "exhaustive", 0),    # wfull=18: exhaustive at the minimum WMAN
    ("w6_m16_random", 6, 16, "random", 512),          # minimum exp2/log2 table width with a wider exponent
    ("w8_m24_random", 8, 24, "random", 1024),
    ("w8_m32_random", 8, 32, "random", 768),
    ("w11_m53_random", 11, 53, "random", 384),
    # Wide-exponent guard: WMAN=16 (the minimum) keeps the datapath small while WEXP=20 (vs <=11 elsewhere) and the
    # directed overflow/underflow/inf/pow2 corners exercise the wide-exponent reduction, OOR threshold, and clamp.
    ("w20_m16_random", 20, 16, "random", 2000),
]
TRANS_EXPLOG_EXT = [
    (2, 16, "exhaustive", 0), (3, 16, "exhaustive", 0),   # exhaustive at the minimum WMAN, two WEXP
    (8, 27, "random", 512), (8, 32, "random", 512),       # mid-range supported WMAN
    (14, 16, "random", 2000),  # wide exponent field (exhaustive infeasible above tiny WEXP), random sweep instead
]

# sincos/atan2 still support WMAN=11 via the CORDIC generator, so their low-cost coverage stays at WMAN=11.
TRANS_TRIG = [
    ("w2_m11_exhaustive", 2, 11, "exhaustive", 0),
    ("w3_m11_exhaustive", 3, 11, "exhaustive", 0),
    ("w5_m11_random", 5, 11, "random", 512),
    ("w8_m24_random", 8, 24, "random", 1024),
    ("w8_m32_random", 8, 32, "random", 768),
    ("w11_m53_random", 11, 53, "random", 384),
    ("w20_m11_random", 20, 11, "random", 2000),
]
TRANS_TRIG_EXT = [
    (2, 11, "exhaustive", 0), (3, 11, "exhaustive", 0),
    (6, 16, "random", 512), (8, 27, "random", 512), (8, 32, "random", 512),
    (14, 11, "random", 2000),
]

# zkf_atan2 is two-input, so joint-exhaustive (2**(2*wfull)) is infeasible even at the minimum WMAN -- every format
# uses directed (the full special/axis/diagonal pair table) + random pairs. Covers the two synthesized formats (6/18,
# 8/36) plus the wide-exponent guard.
TRANS_ATAN2 = [
    ("w6_m18_random", 6, 18, "random", 1536),
    ("w8_m24_random", 8, 24, "random", 1024),
    ("w8_m36_random", 8, 36, "random", 768),
    ("w11_m53_random", 11, 53, "random", 384),
    ("w20_m11_random", 20, 11, "random", 2000),
]
# pipe:     (config, width, stages, count)
PIPE = [("w8_n0", 8, 0, 64), ("w8_n4", 8, 4, 96), ("w24_n2", 24, 2, 96)]
# from_int/to_int: (config, wexp, wman, wint, kind, count)
FROM_INT = [
    ("w2_m4_int4_exhaustive", 2, 4, 4, "exhaustive", 0),
    ("w3_m4_int8_exhaustive", 3, 4, 8, "exhaustive", 0),
    ("w3_m5_int8_exhaustive", 3, 5, 8, "exhaustive", 0),
    ("w5_m11_int16_random", 5, 11, 16, "random", 512),
    ("w6_m18_int32_random", 6, 18, 32, "random", 768),
    ("w8_m24_int32_random", 8, 24, 32, "random", 1024),
    # Wide WINT (>= ~98 here) makes the leading-one position + BIAS exceed a position-only-sized exponent field; the
    # directed extremes (int_max etc.) overflow to +inf and would regress to +0 if WEU is mis-sized. Exhaustive is
    # infeasible at this width, so directed covers the boundary deterministically.
    ("w6_m18_int128_directed", 6, 18, 128, "directed", 0),
]
TO_INT = FROM_INT + [("w11_m53_int32_random", 11, 53, 32, "random", 384)]
# resize: (config, wexp_in, wman_in, wexp_out, wman_out, kind, count). Covers every (WMAN, WEXP) relation
# quadrant so each elaboration-time branch in zkf_resize is exercised: widen-only fast path (3/4->3/4
# same, 3/4->4/4, 3/4->4/6, 3/4->3/6, 5/11->6/18); pack/g_widen slow path (5/4->3/4 g_same_width,
# 5/4->3/6 g_zero_pad); pack/g_narrow slow path (3/5->3/4 DROP=1, 4/6->3/4 DROP=2, 6/18->5/11 DROP=7,
# plus deep 8/24->6/18 and 11/53->8/24).
RESIZE = [
    ("w3_m4_to_w3_m4_exhaustive", 3, 4, 3, 4, "exhaustive", 0),
    ("w3_m4_to_w4_m4_exhaustive", 3, 4, 4, 4, "exhaustive", 0),
    ("w3_m4_to_w3_m6_exhaustive", 3, 4, 3, 6, "exhaustive", 0),
    ("w3_m5_to_w3_m4_exhaustive", 3, 5, 3, 4, "exhaustive", 0),
    ("w3_m4_to_w4_m6_exhaustive", 3, 4, 4, 6, "exhaustive", 0),
    ("w4_m6_to_w3_m4_exhaustive", 4, 6, 3, 4, "exhaustive", 0),
    ("w5_m4_to_w3_m4_exhaustive", 5, 4, 3, 4, "exhaustive", 0),
    ("w5_m4_to_w3_m6_exhaustive", 5, 4, 3, 6, "exhaustive", 0),
    ("w6_m18_to_w5_m11_random", 6, 18, 5, 11, "random", 768),
    ("w5_m11_to_w6_m18_random", 5, 11, 6, 18, "random", 768),
    ("w8_m24_to_w6_m18_random", 8, 24, 6, 18, "random", 512),
    ("w11_m53_to_w8_m24_random", 11, 53, 8, 24, "random", 384),
]

# extended (deep) format lists (formerly BIN_EXT / DIV_EXT / UNARY_EXT in run_extended.sh).
BIN_EXT = [
    (2, 5, "exhaustive", 0), (4, 5, "exhaustive", 0), (2, 7, "exhaustive", 0), (3, 6, "exhaustive", 0),
    (5, 4, "exhaustive", 0), (4, 6, "exhaustive", 0), (3, 7, "random", 512), (6, 17, "random", 768),
    (8, 23, "random", 768), (7, 12, "random", 512), (9, 24, "random", 512), (6, 19, "random", 512),
]
DIV_EXT = [
    (2, 5, "exhaustive", 0), (4, 5, "exhaustive", 0), (3, 6, "exhaustive", 0), (5, 4, "exhaustive", 0),
    (6, 17, "random", 512), (8, 23, "random", 512), (7, 12, "random", 512),
]
UNARY_EXT = [
    (2, 5, "exhaustive", 0), (4, 5, "exhaustive", 0), (3, 6, "exhaustive", 0),
    (6, 17, "random", 512), (8, 23, "random", 512),
]
# fma deep formats: all random (ternary-exhaustive is infeasible above wfull=6). (wexp, wman, kind, count)
FMA_EXT = [
    (4, 5, "random", 512), (3, 6, "random", 512), (5, 4, "random", 512), (3, 7, "random", 512),
    (6, 17, "random", 768), (8, 23, "random", 512), (7, 12, "random", 512), (9, 24, "random", 512),
]


@dataclass
class Run:
    module: str          # mul, add, pack, to_int, pipe, lod, rshift, ...
    sim: str             # icarus | verilator
    tier: str            # pr | deep | properties | fast
    config: str          # final config name (with knob suffixes)
    target: str          # fusesoc target, e.g. sim_mul_icarus
    root: str            # build root
    vlog: list           # [(name, value), ...]  -> --NAME value
    plus: list           # [(name, value), ...]  -> --ZKF_... value
    defines: list = field(default_factory=list)   # [(name, value), ...] -> vlogdefine parameters

    @property
    def id(self) -> str:
        return f"{self.tier}-{self.module}-{self.sim}-{self.config}"


def _root(tier: str, sim: str, module: str, config: str) -> str:
    if tier == "fast":
        return f"build/float/fast/{config}"
    base = {
        ("pr", "icarus"): "icarus",
        ("pr", "verilator"): "verilator",
        ("deep", "icarus"): "icarus-ext",
        ("deep", "verilator"): "verilator-toggle",
        ("properties", "icarus"): "properties",
    }[(tier, sim)]
    return f"build/float/{base}/{module}/{config}"


def _common(kind: str, count: int, config: str, with_kind: bool = True) -> list:
    parts = [("ZKF_KIND", kind)] if with_kind else []
    return parts + [("ZKF_COUNT", count), ("ZKF_SEED", SEED), ("ZKF_CONFIG", config)]


def _run(module, sim, tier, config, vlog, *, kind="exhaustive", count=0,
         target=None, with_kind=True, plus_names=None, root_module=None, defines=None) -> Run:
    """Assemble one Run. vlog params are mirrored to plusargs as ZKF_<name> unless plus_names overrides."""
    plus_names = plus_names or {}
    plus = [(plus_names.get(name, "ZKF_" + name), val) for name, val in vlog]
    plus += _common(kind, count, config, with_kind=with_kind)
    target = target or f"sim_{module}_{sim}"
    root = _root(tier, sim, root_module or module, config)
    return Run(module, sim, tier, config, target, root, vlog, plus, list(defines or []))


# --- builders that mirror the former bash helpers -------------------------------------------------
def _binary(module, sim, tier, base, w, m, kind, count, *, sp=None, si=None, sd=None, sa=None, sn=None,
            pa=None, so=None, wm=None, target=None, root_module=None) -> Run:
    # wm (WMULTIPLIER) is only meaningful for the multiply (zkf_mul); the other _binary ops do not declare it.
    vlog = [("WEXP", w), ("WMAN", m)]
    suffix = ""
    if sp is not None:
        vlog.append(("STAGE_PRODUCT", sp)); suffix += f"_sp{sp}"
    if wm is not None:
        vlog.append(("WMULTIPLIER", wm)); suffix += f"_wm{wm}"
    if si is not None:
        vlog.append(("STAGE_INPUT", si)); suffix += f"_si{si}"
    if sd is not None and sa is not None:
        vlog += [("STAGE_DECODE", sd), ("STAGE_ALIGN", sa)]; suffix += f"_sd{sd}_sa{sa}"
    elif sd is not None:
        vlog.append(("STAGE_DECODE", sd)); suffix += f"_sd{sd}"
    if sn is not None:
        vlog.append(("STAGE_NORMALIZE", sn)); suffix += f"_sn{sn}"
    if pa is not None:
        vlog.append(("STAGE_PACK", pa)); suffix += f"_pa{pa}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run(module, sim, tier, base + suffix, vlog, kind=kind, count=count,
                target=target, root_module=root_module)


def _fma(sim, tier, base, w, m, kind, count, *, sp=None, si=None, sd=None, sa=None, sn=None, pa=None, so=None,
         wm=None) -> Run:
    vlog = [("WEXP", w), ("WMAN", m)]
    suffix = ""
    if sp is not None:
        vlog.append(("STAGE_PRODUCT", sp)); suffix += f"_sp{sp}"
    if wm is not None:
        vlog.append(("WMULTIPLIER", wm)); suffix += f"_wm{wm}"
    if si is not None:
        vlog.append(("STAGE_INPUT", si)); suffix += f"_si{si}"
    if sd is not None:
        vlog.append(("STAGE_DECODE", sd)); suffix += f"_sd{sd}"
    if sa is not None:
        vlog.append(("STAGE_ALIGN", sa)); suffix += f"_sa{sa}"
    if sn is not None:
        vlog.append(("STAGE_NORMALIZE", sn)); suffix += f"_sn{sn}"
    if pa is not None:
        vlog.append(("STAGE_PACK", pa)); suffix += f"_pa{pa}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run("fma", sim, tier, base + suffix, vlog, kind=kind, count=count)


def _pack(sim, tier, config, w, m, u, kind, count, *, so=None, eb=None, nov=None) -> Run:
    vlog = [("WEXP", w), ("WMAN", m), ("WEXP_UNBIASED", u)]
    suffix = ""
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    if eb is not None:
        vlog.append(("EXP_IS_BIASED", eb)); suffix += f"_eb{eb}"
    if nov is not None:
        vlog.append(("ASSUME_NO_OVERFLOW", nov)); suffix += f"_nov{nov}"
    return _run("pack", sim, tier, config + suffix, vlog, kind=kind, count=count)


def _cast(module, sim, tier, base, w, m, wint, kind, count, si, *, sn=None, pa=None, so=None) -> Run:
    vlog = [("WEXP", w), ("WMAN", m), ("WINT", wint), ("STAGE_INPUT", si)]
    suffix = f"_si{si}"
    if sn is not None:
        vlog.append(("STAGE_NORMALIZE", sn)); suffix += f"_sn{sn}"
    if pa is not None:
        vlog.append(("STAGE_PACK", pa)); suffix += f"_pa{pa}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run(module, sim, tier, f"{base}{suffix}", vlog, kind=kind, count=count)


def _resize(sim, tier, base, wi, mi, wo, mo, kind, count, si, so=None) -> Run:
    vlog = [("WEXP_IN", wi), ("WMAN_IN", mi), ("WEXP_OUT", wo), ("WMAN_OUT", mo), ("STAGE_INPUT", si)]
    suffix = f"_si{si}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run("resize", sim, tier, f"{base}{suffix}", vlog, kind=kind, count=count)


def _round(sim, tier, base, w, m, kind, count, *, si=None, sd=None, pa=None, so=None) -> Run:
    vlog = [("WEXP", w), ("WMAN", m)]
    suffix = ""
    if si is not None:
        vlog.append(("STAGE_INPUT", si)); suffix += f"_si{si}"
    if sd is not None:
        vlog.append(("STAGE_DECODE", sd)); suffix += f"_sd{sd}"
    if pa is not None:
        vlog.append(("STAGE_PACK", pa)); suffix += f"_pa{pa}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run("round", sim, tier, f"{base}{suffix}", vlog, kind=kind, count=count)


def _pipe(sim, tier, config, w, n, count) -> Run:
    return _run("pipe", sim, tier, config, [("W", w), ("N", n)], count=count, with_kind=False,
                plus_names={"W": "ZKF_PIPE_W", "N": "ZKF_PIPE_N"})


def _trans(module, sim, tier, base, w, m, kind, count, *,
           si=None, sr=None, sd=None, sp=None, spf=None, sn=None, sno=None, pa=None, so=None, un=None, parallel=None,
           wm=None) -> Run:
    # Each module takes only its own knobs (passing an undeclared parameter makes fusesoc error). exp2/log2 use
    # si/sp/so (STAGE_INPUT/PRODUCT/OUTPUT) and wm (WMULTIPLIER, the _zkf_pmul DSP-tile-grid hint); exp2 also uses
    # sr (STAGE_REDUCE); log2 also uses sd/spf/sno (STAGE_DECODE/PRODUCT_FINAL/NORMALIZE_OUTPUT); sincos and atan2 use
    # un (UNROLL100), parallel (PARALLEL, decoupled z-path), si/so, sp, sn, pa, wm.
    vlog = [("WEXP", w), ("WMAN", m)]
    suffix = ""
    if un is not None:
        vlog.append(("UNROLL100", un)); suffix += f"_un{un}"
    if parallel is not None:
        vlog.append(("PARALLEL", parallel)); suffix += f"_par{parallel}"
    if si is not None:
        vlog.append(("STAGE_INPUT", si)); suffix += f"_si{si}"
    if module == "exp2" and sr is not None:
        vlog.append(("STAGE_REDUCE", sr)); suffix += f"_sr{sr}"
    if module == "log2" and sd is not None:
        vlog.append(("STAGE_DECODE", sd)); suffix += f"_sd{sd}"
    if sp is not None:
        vlog.append(("STAGE_PRODUCT", sp)); suffix += f"_sp{sp}"
    if module == "log2":
        spf_eff = sp if spf is None else spf
        if spf_eff is not None:
            vlog.append(("STAGE_PRODUCT_FINAL", spf_eff)); suffix += f"_spf{spf_eff}" if spf is not None else ""
    if wm is not None:
        vlog.append(("WMULTIPLIER", wm)); suffix += f"_wm{wm}"
    if sn is not None:
        vlog.append(("STAGE_NORMALIZE", sn)); suffix += f"_sn{sn}"
    if module == "log2" and sno is not None:
        vlog.append(("STAGE_NORMALIZE_OUTPUT", sno)); suffix += f"_sno{sno}"
    if pa is not None:
        vlog.append(("STAGE_PACK", pa)); suffix += f"_pa{pa}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run(module, sim, tier, base + suffix, vlog, kind=kind, count=count)


# --- the matrix -----------------------------------------------------------------------------------
def _per_pr(sim, out: list) -> None:
    for cfg, w, m, u, k, c in PACK:
        out.append(_pack(sim, "pr", cfg, w, m, u, k, c))
    for op in ("cmp", "sort"):
        for cfg, w, m, k, c in BINARY:
            out.append(_binary(op, sim, "pr", cfg, w, m, k, c))
        # New uniform STAGE_INPUT knob for cmp/sort: exercise on a fast exhaustive format.
        out.append(_binary(op, sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=1))
    for op in ("add", "addsub"):
        for sd in (0, 1):
            for sa in (0, 1):
                for cfg, w, m, k, c in BINARY:
                    out.append(_binary(op, sim, "pr", cfg, w, m, k, c, sd=sd, sa=sa))
        # New uniform STAGE_INPUT and STAGE_PACK knobs for add/addsub: exercise each on a fast exhaustive format,
        # plus the all-on combination so a future register-stage change cannot silently break the latency bookkeeping.
        out.append(_binary(op, sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=1))
        out.append(_binary(op, sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, pa=1))
        out.append(_binary(op, sim, "pr", "w3_m4_maxpipe", 3, 4, "exhaustive", 0, sd=1, sa=1, sn=1, pa=1,
                           si=2, so=1))
        # Arbitrary STAGE_INPUT (>1 dummy input stages): isolated exhaustive (si=3) + a wider random (si=2) exercise
        # the counted-latency bookkeeping and the multi-stage input pipe beyond the former {0,1} range.
        out.append(_binary(op, sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=3))
        out.append(_binary(op, sim, "pr", "w8_m18", 8, 18, "random", 256, si=2))
        # STAGE_NORMALIZE knob (new): forwards to _zkf_normshift.STAGE_SPLIT for the close-cancel path. SN=1
        # matches today's silent SS=1 (same latency, different register placement); SN=2 adds an s2x catch-up
        # cycle. The normshift needs NL4 >= 3 for SN=2, which requires NINPUT = WMAN+3 >= 11 -> WMAN >= 8.
        for sn in (1,):
            out.append(_binary(op, sim, "pr", "w4_m6_sn", 4, 6, "random", 256, sn=sn))
        out.append(_binary(op, sim, "pr", "w8_m18_sn2", 8, 18, "random", 256, sd=1, sa=1, sn=2))
    for sp in (0, 1):
        for si in (0, 1):
            for cfg, w, m, k, c in BINARY:
                out.append(_binary("mul", sim, "pr", cfg, w, m, k, c, sp=sp, si=si))
    # New uniform STAGE_PACK knob (forwards to _zkf_pack.STAGE_INPUT) for mul: standalone and full-shield check.
    out.append(_binary("mul", sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, pa=1))
    out.append(_binary("mul", sim, "pr", "w3_m4_maxpipe", 3, 4, "exhaustive", 0, sp=1, si=1, pa=1, so=1))
    # STAGE_PRODUCT 2/3 (widened from {0,1}) forward to _zkf_pmul's 2x2 / 3x3 split grids; exercise both split depths
    # for bit-exactness + the latency bookkeeping on a fast exhaustive format.
    out.append(_binary("mul", sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, sp=2))
    out.append(_binary("mul", sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, sp=3))
    for si in (0, 1):
        for cfg, w, m, k, c in BINARY:
            out.append(_binary("div", sim, "pr", cfg, w, m, k, c, si=si))
    # New uniform STAGE_PACK knob for div: standalone exercise.
    out.append(_binary("div", sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, pa=1))
    out.append(_binary("div", sim, "pr", "w3_m4_maxpipe", 3, 4, "exhaustive", 0, si=1, pa=1, so=1))
    for cfg, w, m, k, c in FMA:
        out.append(_fma(sim, "pr", cfg, w, m, k, c))
    # Each pipeline knob exercised once (plus all-on) on a fast format. Results are staging-independent, so this
    # validates the out_valid timing of every STAGE_* register without re-running the slow formats.
    for si, sp, sd, sa, sn, pa, so in [(0, 0, 0, 0, 0, 0, 0), (1, 0, 0, 0, 0, 0, 0), (0, 1, 0, 0, 0, 0, 0),
                                       (0, 0, 1, 0, 0, 0, 0), (0, 0, 0, 1, 0, 0, 0), (0, 0, 0, 0, 1, 0, 0),
                                       (0, 0, 0, 0, 0, 1, 0), (0, 0, 0, 0, 0, 0, 1), (1, 1, 1, 1, 1, 1, 1)]:
        out.append(_fma(sim, "pr", "w4_m6_stage", 4, 6, "random", 256,
                        sp=sp, si=si, sd=sd, sa=sa, sn=sn, pa=pa, so=so))
    # STAGE_PRODUCT 2/3 (widened from {0,1}) forward to _zkf_pmul's 2x2 / 3x3 split grids; exercise both on the fast
    # format for bit-exactness + the latency bookkeeping.
    out.append(_fma(sim, "pr", "w4_m6_stage", 4, 6, "random", 256, sp=2))
    out.append(_fma(sim, "pr", "w4_m6_stage", 4, 6, "random", 256, sp=3))
    # STAGE_NORMALIZE=2 (FMA-local 3-segment normalizer) needs NL4 = ($clog2(2*WMAN+3)+1)/2 >= 3, i.e. WMAN >= 7
    # (smaller WMAN collapses its two register barriers and is rejected at elaboration), so it cannot use the w4/m6
    # knob format above. Exercise it at the WMAN=7 guard boundary - the smallest format permitted, and a WINDEX-
    # dominated WEU corner - and at a wider WMAN=18 so CI covers both the guard edge and the +1-stage timing.
    out.append(_fma(sim, "pr", "w4m7_sn2", 4, 7, "random", 384, sp=1, sd=1, sa=1, sn=2))
    out.append(_fma(sim, "pr", "w6m18_sn2", 6, 18, "random", 384, sp=1, sd=1, sa=1, sn=2))
    # STAGE_NORMALIZE=2 with STAGE_OUTPUT=1 is otherwise untested (every other sn=2 entry has so=0): guard the
    # deepest pipeline - the 3-segment normalizer's payload realignment feeding the registered packer output - with
    # every stage knob on at once, so a future packer/output-register change cannot silently break it.
    out.append(_fma(sim, "pr", "w6m18_maxpipe", 6, 18, "random", 384, sp=1, si=1, sd=1, sa=1, sn=2, so=1))
    # The narrow synth/CI config ships as STAGE_INPUT=1 + STAGE_ALIGN=1 + STAGE_NORMALIZE=2 (closes every W6/M18
    # datapath cone on both Yosys and the more pessimistic Diamond/LSE with a single MULT18X18D - STAGE_PRODUCT=1
    # would split the 18x18 into a 2x2 grid costing 4 DSPs for no timing gain); gate that exact stage combination so
    # the shipped config's correctness is tested directly, not just inferred from the per-knob sweeps.
    out.append(_fma(sim, "pr", "w6m18_si1_sa1_sn2", 6, 18, "random", 384, si=1, sa=1, sn=2))
    for op in ("abs", "neg", "is_finite", "saturate"):
        for cfg, w, m, k, c in UNARY:
            out.append(_binary(op, sim, "pr", cfg, w, m, k, c))
    for op in ("exp2", "log2"):
        for cfg, w, m, k, c in TRANS_EXPLOG:
            out.append(_trans(op, sim, "pr", cfg, w, m, k, c))
    for cfg, w, m, k, c in TRANS_TRIG:
        for op in ("sincos",):
            out.append(_trans(op, sim, "pr", cfg, w, m, k, c))
    for op in ("exp2", "log2"):
        # STAGE_INPUT / STAGE_PRODUCT / STAGE_OUTPUT timing coverage on the cheapest exhaustive format (results
        # are staging-independent, so these only exercise the register-stage bookkeeping and the optional registers).
        # sincos shares STAGE_INPUT/STAGE_PRODUCT/STAGE_OUTPUT, plus its own UNROLL100 / STAGE_NORMALIZE / STAGE_PACK
        # staging (the decode and wide-datapath register stages are always-on) -- all covered in its own rows below.
        out.append(_trans(op, sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, si=1))
        out.append(_trans(op, sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, so=1))
        out.append(_trans(op, sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, sp=1))
        out.append(_trans(op, sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, sp=2))
        out.append(_trans(op, sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, sp=3))
        out.append(_trans(op, sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, si=1, sp=1, so=1))
    out.append(_trans("exp2", sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, sr=1))
    out.append(_trans("log2", sim, "pr", "w6_m16_decode", 6, 16, "random", 256, sd=1))
    out.append(_trans("log2", sim, "pr", "w6_m16_split_final", 6, 16, "random", 256, sp=1, spf=2))
    # sincos throughput knob UNROLL100 (iterations/cycle x100): 50 = half-rate 2-cycle engine, 100 = the synthesized
    # M18 rate, 200 = 2/cycle. Each changes the published II, so exercise it -- the test asserts measured == model.
    out.append(_trans("sincos", sim, "pr", "w5_m11_unroll", 5, 11, "random", 256, un=50))
    out.append(_trans("sincos", sim, "pr", "w5_m11_unroll", 5, 11, "random", 256, un=200))
    # sincos staging knobs (all bit-transparent vs the unstaged path; the test verifies bit-exactness + the latency
    # model for each). Exercise on the cheap 5/11 format. STAGE_INPUT / STAGE_OUTPUT are the standard sequential-module
    # register stages; the decode and wide-datapath stages are always-on (the synthesized WMAN=36 profile is un=50 +
    # sp=3 + wmultiplier=18).
    out.append(_trans("sincos", sim, "pr", "w5_m11_stage", 5, 11, "random", 256, si=1))
    out.append(_trans("sincos", sim, "pr", "w5_m11_stage", 5, 11, "random", 256, so=1))
    out.append(_trans("sincos", sim, "pr", "w5_m11_stage", 5, 11, "random", 256, si=1, so=1))
    # STAGE_PRODUCT: the shared correction multiply (_zkf_pmul) depth -- 1 = native + operand capture, 2 = 2x2 +
    # capture, 3 = 3x3 + capture + row-sum. Bit-transparent; each adds 2*STAGE_PRODUCT cycles. Exercises every grid.
    out.append(_trans("sincos", sim, "pr", "w5_m11_prod", 5, 11, "random", 256, sp=1))
    out.append(_trans("sincos", sim, "pr", "w5_m11_prod", 5, 11, "random", 256, sp=2))
    out.append(_trans("sincos", sim, "pr", "w5_m11_prod", 5, 11, "random", 256, sp=3))
    out.append(_trans("sincos", sim, "pr", "w5_m11_un50_prod", 5, 11, "random", 256, un=50, parallel=0, sp=2))
    # Decoupled z-path (PARALLEL): the engine runs the narrow z-recurrence at full rate ahead of the half-rate x/y
    # rotator and issues PHI early -- bit-identical to lock-step but with the latency dropped by min(1+STAGE_PRODUCT,
    # gap). PARALLEL is only legal/useful half-rate (it mirrors the synthesized M36 profile), so exercise un=50 with
    # PARALLEL=1 across STAGE_PRODUCT and pin the lock-step half-rate fallback with explicit PARALLEL=0. The test
    # asserts bit-exactness vs the unchanged model AND measured II == model, catching a decouple bug or a latency drift.
    # (Full-rate + PARALLEL is rejected at elaboration -- a full-rate z-chain can't get ahead -- so it is not swept.)
    out.append(_trans("sincos", sim, "pr", "w5_m11_dec", 5, 11, "random", 256, un=50, parallel=1))
    out.append(_trans("sincos", sim, "pr", "w5_m11_dec", 5, 11, "random", 256, un=50, parallel=1, sp=2))
    out.append(_trans("sincos", sim, "pr", "w5_m11_dec", 5, 11, "random", 256, un=50, parallel=1, sp=3))
    out.append(_trans("sincos", sim, "pr", "w5_m11_dec", 5, 11, "random", 256, un=50, parallel=0, sp=3))
    # STAGE_NORMALIZE for log2 / sincos controls the normalizer's STAGE_SPLIT. Cover log2 at the minimum supported
    # table width and sincos on the cheap 5/11 CORDIC format.
    out.append(_trans("log2", sim, "pr", "w6_m16_sncheck", 6, 16, "random", 256, sn=1))
    out.append(_trans("log2", sim, "pr", "w6_m16_sncheck", 6, 16, "random", 256, sp=1, sn=1))
    out.append(_trans("log2", sim, "pr", "w8_m24_sncheck", 8, 24, "random", 256, sn=2, pa=1))
    # Exercise log2's STAGE_NORMALIZE_OUTPUT integration (the registered _zkf_normshift output + its pole/domain
    # sideband alignment); no other matrix row drives sno, and no shipped synth config uses it.
    out.append(_trans("log2", sim, "pr", "w6_m16_sno", 6, 16, "random", 256, sn=1, sno=1, pa=1))
    out.append(_trans("sincos", sim, "pr", "w5_m11_sncheck", 5, 11, "random", 256, sn=1))
    out.append(_trans("sincos", sim, "pr", "w5_m11_sncheck", 5, 11, "random", 256, sn=2))
    # STAGE_PACK is a uniform knob (forwards to _zkf_pack.STAGE_INPUT) on exp2/log2/sincos. Exercise it on the
    # cheapest exhaustive format: standalone and in combination with the other staging knobs.
    out.append(_trans("exp2", sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, pa=1))
    out.append(_trans("log2", sim, "pr", "w2_m16_exhaustive", 2, 16, "exhaustive", 0, pa=1))
    out.append(_trans("sincos", sim, "pr", "w2_m11_exhaustive", 2, 11, "exhaustive", 0, pa=1))
    out.append(_trans("log2", sim, "pr", "w6_m16_sncheck", 6, 16, "random", 256, sn=1, pa=1))
    out.append(_trans("sincos", sim, "pr", "w5_m11_sncheck", 5, 11, "random", 256, sn=1, pa=1))
    # Exact small log2 synthesis presets: the shipped 6/18 rows use STAGE_NORMALIZE=1 + the final-multiply
    # operand-capture (STAGE_PRODUCT_FINAL=1), so cover them at PR depth to pin the latency and the pole/domain-error
    # sideband alignment under those exact knobs.
    out.append(_trans("log2", sim, "pr", "w6_m18_synth", 6, 18, "random", 512, sn=1, spf=1))
    out.append(_trans("log2", sim, "pr", "w6_m18_synth_so1", 6, 18, "random", 512, sn=2, spf=1, so=1))
    # zkf_atan2 (two-input vectoring CORDIC): directed pair table + random across formats, then the shared knob sweeps
    # (UNROLL100 throughput; STAGE_INPUT/OUTPUT/NORMALIZE/PACK staging). Each row asserts bit-exactness vs the model and
    # measured II == atan2_latency. Directed alone exercises every special/axis/diagonal/bypass-boundary pair.
    for cfg, w, m, k, c in TRANS_ATAN2:
        out.append(_trans("atan2", sim, "pr", cfg, w, m, k, c))
    # Tiny WEXP (2, 3): random covers the generic path (the narrow exponent-difference width) AND the directed special
    # pairs (the axis/diagonal turn constants that underflow the normal range at small BIAS).
    out.append(_trans("atan2", sim, "pr", "w2_m11_random", 2, 11, "random", 512))
    out.append(_trans("atan2", sim, "pr", "w3_m11_random", 3, 11, "random", 512))
    out.append(_trans("atan2", sim, "pr", "w6_m18_directed", 6, 18, "directed", 0))
    out.append(_trans("atan2", sim, "pr", "w5_m11_unroll", 5, 11, "random", 256, un=50))
    out.append(_trans("atan2", sim, "pr", "w5_m11_unroll", 5, 11, "random", 256, un=200))
    out.append(_trans("atan2", sim, "pr", "w5_m11_unroll", 5, 11, "random", 256, un=400))
    out.append(_trans("atan2", sim, "pr", "w5_m11_stage", 5, 11, "random", 256, si=1))
    out.append(_trans("atan2", sim, "pr", "w5_m11_stage", 5, 11, "random", 256, so=1))
    out.append(_trans("atan2", sim, "pr", "w5_m11_stage", 5, 11, "random", 256, si=1, so=1))
    out.append(_trans("atan2", sim, "pr", "w5_m11_norm", 5, 11, "random", 256, sn=1))
    out.append(_trans("atan2", sim, "pr", "w5_m11_norm", 5, 11, "random", 256, sn=2))
    out.append(_trans("atan2", sim, "pr", "w5_m11_pack", 5, 11, "random", 256, pa=1))
    out.append(_trans("atan2", sim, "pr", "w5_m11_full", 5, 11, "random", 256, si=1, sn=2, pa=1, so=1))
    # STAGE_PRODUCT / WMULTIPLIER: the shared _zkf_pmul (magnitude x_K*KINV and the residual/bypass Q*INV_TAU). Each
    # adds STAGE_PRODUCT cycles; bit-transparent. Exercise the native (sp=1) and the 2x2 (sp=2) tile-grid splits, plus
    # the synthesized 6/18 operating point (half-rate engine + the staged DSP-tile-grid product + back-end stages).
    out.append(_trans("atan2", sim, "pr", "w5_m11_prod", 5, 11, "random", 256, sp=1))
    out.append(_trans("atan2", sim, "pr", "w5_m11_prod", 5, 11, "random", 256, sp=2, wm=16))
    out.append(_trans("atan2", sim, "pr", "w6_m18_synth", 6, 18, "random", 256,
                      un=50, sp=2, wm=18, sn=2, pa=1))
    # The shipped zkf_atan2_w8m36 synth config (UNROLL100=50, STAGE_PRODUCT=4, WMULTIPLIER=18, STAGE_NORMALIZE=2,
    # STAGE_PACK=1, STAGE_OUTPUT=1) tested directly so its correctness + data-independent latency
    # are checked, not just inferred from the knob sweeps.
    out.append(_trans("atan2", sim, "pr", "w8_m36_synth", 8, 36, "random", 256,
                      un=50, sp=4, wm=18, sn=2, pa=1, so=1))
    for sd in (0, 1):
        for cfg, w, m, k, c in UNARY:
            out.append(_binary("mul_ilog2_const", sim, "pr", cfg, w, m, k, c, sd=sd))
    # New uniform STAGE_INPUT knob for mul_ilog2_const: standalone and combined with STAGE_DECODE.
    out.append(_binary("mul_ilog2_const", sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=1))
    out.append(_binary("mul_ilog2_const", sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=1, sd=1))
    for si in (0, 1):
        for cfg, w, m, wint, k, c in FROM_INT:
            out.append(_cast("from_int", sim, "pr", cfg, w, m, wint, k, c, si))
        for cfg, w, m, wint, k, c in TO_INT:
            out.append(_cast("to_int", sim, "pr", cfg, w, m, wint, k, c, si))
        for cfg, wi, mi, wo, mo, k, c in RESIZE:
            out.append(_resize(sim, "pr", cfg, wi, mi, wo, mo, k, c, si))
    # New uniform knobs on zkf_from_int (STAGE_NORMALIZE forwarded to _zkf_normshift.STAGE_SPLIT, STAGE_PACK
    # forwarded to _zkf_pack.STAGE_INPUT). Exercise on a fast exhaustive format.
    out.append(_cast("from_int", sim, "pr", "w3_m4_int8_exhaustive", 3, 4, 8, "exhaustive", 0, si=0, sn=1))
    out.append(_cast("from_int", sim, "pr", "w3_m4_int8_exhaustive", 3, 4, 8, "exhaustive", 0, si=0, pa=1))
    out.append(_cast("from_int", sim, "pr", "w3_m4_int8_exhaustive", 3, 4, 8, "exhaustive", 0, si=1, sn=1, pa=1))
    # zkf_round: every operand is swept across all four rounding modes by the bench. UNARY covers the formats
    # (w2_m4 exhaustive reaches the round-up-overflows-to-inf corner). The stage knobs (STAGE_INPUT via zkf_pipe,
    # STAGE_PACK -> _zkf_pack.STAGE_INPUT, STAGE_OUTPUT -> _zkf_pack.STAGE_OUTPUT) are exercised once each plus
    # all-on on a fast exhaustive format so a latency-bookkeeping regression is caught cheaply.
    for cfg, w, m, k, c in UNARY:
        out.append(_round(sim, "pr", cfg, w, m, k, c))
    out.append(_round(sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=1))
    out.append(_round(sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, sd=1))
    out.append(_round(sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, pa=1))
    out.append(_round(sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, so=1))
    out.append(_round(sim, "pr", "w3_m4_maxpipe", 3, 4, "exhaustive", 0, si=1, sd=1, pa=1, so=1))
    out.append(_binary("add", sim, "pr", "w6_m100_directed", 6, 100, "directed", 0))  # one-off
    for cfg, w, n, c in PIPE:
        out.append(_pipe(sim, "pr", cfg, w, n, c))
    # Arbitrary STAGE_INPUT (>1 dummy input stages) across the generalized public modules: a latency-checked si=2 per
    # module (+ si=3 on the multiplier) confirms the widened input pipe and the _count(stage_input) latency model agree
    # beyond the former {0,1}. sincos/atan2 are excluded (handshake-entangled input stage; deferred).
    for op in ("mul", "div", "cmp", "sort"):
        out.append(_binary(op, sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=2))
    out.append(_binary("mul", sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=3))
    out.append(_binary("mul_ilog2_const", sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=2))
    out.append(_fma(sim, "pr", "w4_m6", 4, 6, "random", 256, si=2))
    out.append(_round(sim, "pr", "w3_m4", 3, 4, "exhaustive", 0, si=2))
    out.append(_cast("from_int", sim, "pr", "w3_m4_int8", 3, 4, 8, "exhaustive", 0, 2))
    out.append(_cast("to_int", sim, "pr", "w3_m4_int8", 3, 4, 8, "exhaustive", 0, 2))
    out.append(_resize(sim, "pr", "w3m4_to_w4m6", 3, 4, 4, 6, "exhaustive", 0, 2))
    for op in ("exp2", "log2"):
        out.append(_trans(op, sim, "pr", "w2_m16", 2, 16, "exhaustive", 0, si=2))


def _deep_correctness(out: list) -> None:
    # Full Cartesian product of each module's structural knobs, swept across every format in its deep list, so every
    # parameter combination is exercised for correctness. (Coverage closure lives in _deep_coverage under merged-union
    # semantics.) Knob axes: mul = STAGE_INPUT x STAGE_PRODUCT x STAGE_OUTPUT;
    # add/addsub = STAGE_DECODE x STAGE_ALIGN x STAGE_OUTPUT;
    # div/from_int/resize = STAGE_INPUT x STAGE_OUTPUT; to_int = STAGE_INPUT only (no STAGE_OUTPUT); pack = STAGE_OUTPUT
    # x EXP_IS_BIASED; mul_ilog2_const = STAGE_DECODE x K (K already fanned out by its wrapper).
    s = "icarus"
    for w, m, k, c in BIN_EXT:
        base = f"w{w}m{m}_{k}"
        for sp in (0, 1, 2, 3):  # _zkf_pmul depth: single / capture+native / 2x2 / 3x3
            for si in (0, 1):
                for so in (0, 1):
                    out.append(_binary("mul", s, "deep", base, w, m, k, c, sp=sp, si=si, so=so))
        for op in ("add", "addsub"):
            for sd in (0, 1):
                for sa in (0, 1):
                    for so in (0, 1):
                        out.append(_binary(op, s, "deep", base, w, m, k, c, sd=sd, sa=sa, so=so))
        out.append(_binary("cmp", s, "deep", base, w, m, k, c))
        out.append(_binary("sort", s, "deep", base, w, m, k, c))
    # fma: each deep format once for correctness (results are staging-independent), the full pipeline-knob
    # cartesian on one fast format to validate every STAGE_* timing combination, the WEXP=8/WMAN=36 gated synth
    # config, and the smallest format exhaustively at the staging extremes.
    for w, m, k, c in FMA_EXT:
        out.append(_fma(s, "deep", f"w{w}m{m}_{k}", w, m, k, c))
    for sp in (0, 1):
        for si in (0, 1):
            for sd in (0, 1):
                for sa in (0, 1):
                    for sn in (0, 1):
                        for so in (0, 1):
                            out.append(_fma(s, "deep", "w4m6_knobs", 4, 6, "random", 256,
                                            sp=sp, si=si, sd=sd, sa=sa, sn=sn, so=so))
    out.append(_fma(s, "deep", "w8m36", 8, 36, "random", 768, sp=1, sd=1, sa=1, sn=2))
    out.append(_fma(s, "deep", "w8m36_si1", 8, 36, "random", 768, sp=1, si=1, sd=1, sa=1, sn=2))
    # Widened STAGE_PRODUCT split depths (2 = 2x2, 3 = 3x3) on the wide WMAN=36 format where the multi-tile grid
    # actually matters, with a WMULTIPLIER=18 pin so _zkf_pmul derives the 18-bit DSP-tile grid rather than symmetric.
    # sp=2 is the depth the synthesized zkf_fma_w8m36 ships; sp=3 additionally exercises the 3x3 grid end to end.
    out.append(_fma(s, "deep", "w8m36", 8, 36, "random", 768, sp=2, wm=18, sd=1, sa=1, sn=2))
    out.append(_fma(s, "deep", "w8m36", 8, 36, "random", 768, sp=3, wm=18, sd=1, sa=1, sn=2))
    for si, sp, sd, sa, sn, so in ((0, 0, 0, 0, 0, 0), (1, 1, 1, 1, 1, 1)):
        out.append(_fma(s, "deep", "w2m4_exhaustive", 2, 4, "exhaustive", 0,
                        sp=sp, si=si, sd=sd, sa=sa, sn=sn, so=so))
    for w, m, k, c in DIV_EXT:
        for si in (0, 1):
            for so in (0, 1):
                out.append(_binary("div", s, "deep", f"w{w}m{m}_{k}", w, m, k, c, si=si, so=so))
    # div at WMAN=48 (it uses no transcendental tables, so a wide format is cheap and otherwise untested in CI).
    out.append(_binary("div", s, "deep", "w8m48_random", 8, 48, "random", 384, si=0, so=0))
    for w, m, k, c in UNARY_EXT:
        base = f"w{w}m{m}_{k}"
        for op in ("abs", "neg", "is_finite", "saturate"):
            out.append(_binary(op, s, "deep", base, w, m, k, c))
        for sd in (0, 1):
            out.append(_binary("mul_ilog2_const", s, "deep", base, w, m, k, c, sd=sd))
    # exp2/log2: STAGE_INPUT / STAGE_PRODUCT / STAGE_OUTPUT staging (one knob at a time off the baseline) across the
    # deep transcendental format list.
    for w, m, k, c in TRANS_EXPLOG_EXT:
        base = f"w{w}m{m}_{k}"
        for op in ("exp2", "log2"):
            for si, sp, so in ((0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)):
                out.append(_trans(op, s, "deep", base, w, m, k, c, si=si, sp=sp, so=so))
        out.append(_trans("exp2", s, "deep", base, w, m, k, c, sr=1))
        out.append(_trans("log2", s, "deep", base + "_decode", w, m, k, c, sd=1))
        out.append(_trans("log2", s, "deep", base + "_split_final", w, m, k, c, sp=1, spf=2))

    # sincos sweeps STAGE_PRODUCT (its shared _zkf_pmul split) plus its UNROLL100 throughput knob and
    # STAGE_NORMALIZE / STAGE_PACK; the testbench asserts measured II == model each time.
    for w, m, k, c in TRANS_TRIG_EXT:
        base = f"w{w}m{m}_{k}"
        for un in (50, 100, 200, 400):
            out.append(_trans("sincos", s, "deep", base, w, m, k, c, un=un))
        for sp in (1, 2, 3):
            out.append(_trans("sincos", s, "deep", base, w, m, k, c, sp=sp))
        out.append(_trans("sincos", s, "deep", base, w, m, k, c, si=1, so=1, sn=1, pa=1))
        # The synthesized wide profile's multiply (half-rate engine + 3x3 product split pinned to the WMULTIPLIER=18
        # 18-bit DSP-tile grid, as zkf_sincos_w8m36 ships), bit-transparent vs the unstaged path, across the deep wide
        # formats. STAGE_NORMALIZE / STAGE_PACK are swept separately above; here the focus is the wide multiplier grid.
        out.append(_trans("sincos", s, "deep", base, w, m, k, c, un=50, sp=3, wm=18))
    # The exact synthesized WEXP=8/WMAN=36 multiply-bearing operating points, end to end with WMULTIPLIER=18 (the
    # 18-bit DSP-tile grid the Diamond/LSE flow needs): mul at STAGE_PRODUCT=2, exp2 at STAGE_PRODUCT=3, log2 Horner
    # and the wider final multiply at STAGE_PRODUCT=3, and log2's normalize-shift split at STAGE_NORMALIZE=2 (the row
    # sets sn=2; the normalizer output-register stage STAGE_NORMALIZE_OUTPUT is not used here). WMULTIPLIER is
    # bit-transparent, but pinning the shipped grid here exercises the full datapath at the operating point that
    # synthesis actually builds rather than only the symmetric default.
    out.append(_binary("mul", s, "deep", "w8m36", 8, 36, "random", 512, sp=2, wm=18, pa=1))
    out.append(_trans("exp2", s, "deep", "w8m36", 8, 36, "random", 512, si=1, sp=3, wm=18, so=1))
    out.append(_trans("log2", s, "deep", "w8m36", 8, 36, "random", 512,
                      si=1, sp=3, spf=3, wm=18, sn=2, pa=1))
    # zkf_atan2 deep: a baseline per format, the UNROLL100 throughput sweep + full staging on the cheap 5/11 format,
    # and the exact synthesized 6/18 + 8/36 operating points (half-rate engine + staged back-end).
    # Each asserts II == model.
    for cfg, w, m, k, c in TRANS_ATAN2:
        out.append(_trans("atan2", s, "deep", f"atan2_{cfg}", w, m, k, c))
    for un in (50, 100, 200, 400):
        out.append(_trans("atan2", s, "deep", "atan2_w5m11_un", 5, 11, "random", 512, un=un))
    out.append(_trans("atan2", s, "deep", "atan2_w5m11_stage", 5, 11, "random", 512, si=1, so=1, sn=2, pa=1))
    out.append(_trans("atan2", s, "deep", "atan2_w6m18_op", 6, 18, "random", 512,
                      un=50, sp=2, wm=18, sn=2, pa=1))              # the synthesized 6/18 operating point
    out.append(_trans("atan2", s, "deep", "atan2_w8m36_op", 8, 36, "random", 512,
                      un=50, si=0, sp=4, wm=18, sn=2, pa=1, so=1))  # the synthesized 8/36 operating point
    # pack: STAGE_OUTPUT x EXP_IS_BIASED. EXP_IS_BIASED=1 stimulus is exhaustive-only (test_pack iterates the biased
    # field directly); random formats stay EXP_IS_BIASED=0, which is also exercised transitively via add/from_int.
    for w, m, u, k, c in [(2, 5, 3, "exhaustive", 0), (2, 5, 5, "exhaustive", 0), (3, 5, 5, "exhaustive", 0),
                          (4, 5, 8, "random", 768), (6, 17, 10, "random", 1024), (4, 4, 8, "random", 512)]:
        base = f"w{w}m{m}u{u}_{k}"
        for so in (0, 1):
            out.append(_pack(s, "deep", base, w, m, u, k, c, so=so))
            if k == "exhaustive":
                out.append(_pack(s, "deep", base, w, m, u, k, c, so=so, eb=1))
    for w, m, i, k, c in [(3, 5, 5, "exhaustive", 0), (2, 5, 3, "exhaustive", 0), (4, 5, 7, "exhaustive", 0),
                          (4, 6, 5, "exhaustive", 0), (5, 11, 9, "random", 512), (6, 17, 33, "random", 512),
                          (8, 24, 17, "random", 512)]:
        base = f"w{w}m{m}i{i}_{k}"
        for si in (0, 1):
            out.append(_cast("to_int", s, "deep", base, w, m, i, k, c, si))
            for so in (0, 1):
                out.append(_cast("from_int", s, "deep", base, w, m, i, k, c, si, so=so))
    # from_int at the widest WMAN and at STAGE_NORMALIZE=2: its WX/WEU sizing, carry-to-inf wiring, and the sn=2
    # normalize-shift split are otherwise unexercised (the loop above tops out at WMAN=24 with sn<=1).
    out.append(_cast("from_int", s, "deep", "w11m53i32", 11, 53, 32, "random", 384, 0))
    out.append(_cast("from_int", s, "deep", "w6m18i32_sn2", 6, 18, 32, "random", 256, 0, sn=2))
    for wi, mi, wo, mo, k, c in [(4, 5, 4, 4, "exhaustive", 0), (4, 4, 4, 5, "exhaustive", 0),
                                 (2, 5, 4, 7, "exhaustive", 0), (4, 7, 2, 5, "exhaustive", 0),
                                 (5, 5, 3, 4, "exhaustive", 0), (3, 4, 5, 5, "exhaustive", 0),
                                 (6, 17, 4, 11, "random", 512), (5, 11, 6, 17, "random", 512)]:
        base = f"w{wi}m{mi}_to_w{wo}m{mo}_{k}"
        for si in (0, 1):
            for so in (0, 1):
                out.append(_resize(s, "deep", base, wi, mi, wo, mo, k, c, si, so=so))
    # resize across a wide WMAN=48 (narrow then widen): the WMAN-shrink GRS rounding and the WMAN-grow zero-fill at a
    # wide format are otherwise untested in CI.
    out.append(_resize(s, "deep", "w8m48_to_w8m24", 8, 48, 8, 24, "random", 384, 0))
    out.append(_resize(s, "deep", "w8m24_to_w8m48", 8, 24, 8, 48, "random", 384, 0))
    # round: each unary deep format once for correctness, the full STAGE_INPUT x STAGE_PACK x STAGE_OUTPUT knob
    # cartesian on a small exhaustive format, and the WEXP=8/WMAN=36 wide format (shared with the synth gate).
    for w, m, k, c in UNARY_EXT:
        out.append(_round(s, "deep", f"w{w}m{m}_{k}", w, m, k, c))
    for si in (0, 1):
        for sd in (0, 1):
            for pa in (0, 1):
                for so in (0, 1):
                    out.append(_round(s, "deep", "w3m6_knobs", 3, 6, "exhaustive", 0, si=si, sd=sd, pa=pa, so=so))
    out.append(_round(s, "deep", "w8m36", 8, 36, "random", 768))
    out.append(_round(s, "deep", "w8m36_maxpipe", 8, 36, "random", 768, si=1, sd=1, pa=1, so=1))
    out.append(_round(s, "deep", "w8m48", 8, 48, "random", 384))


def _deep_coverage(out: list) -> None:
    s = "verilator"
    for w, m in [(4, 5), (3, 6), (5, 4), (3, 5), (2, 6)]:
        base = f"w{w}m{m}"
        for sp in (0, 1):
            out.append(_binary("mul", s, "deep", base, w, m, "exhaustive", 0, sp=sp))
        out.append(_binary("add", s, "deep", base, w, m, "exhaustive", 0, sd=0, sa=0))
        out.append(_binary("add", s, "deep", base, w, m, "exhaustive", 0, sd=1, sa=1))
        out.append(_binary("add", s, "deep", base, w, m, "exhaustive", 0, si=2))
        out.append(_binary("addsub", s, "deep", base, w, m, "exhaustive", 0, sd=1, sa=1))
        out.append(_binary("addsub", s, "deep", base, w, m, "exhaustive", 0, si=2))
        out.append(_binary("cmp", s, "deep", base, w, m, "exhaustive", 0))
        out.append(_binary("sort", s, "deep", base, w, m, "exhaustive", 0))
    # fma coverage: W2/M4 exhaustive (the only feasible ternary-exhaustive) at default and all-on staging toggles
    # the product/decode/align/normalize/output split registers; wider random runs toggle the wide shifters and the
    # far-shift saturation path that the tiny W2/M4 exponent range cannot reach.
    out.append(_fma(s, "deep", "w2m4", 2, 4, "exhaustive", 0, sp=0, sd=0, sa=0, sn=0, so=0))
    out.append(_fma(s, "deep", "w2m4", 2, 4, "exhaustive", 0, sp=1, sd=1, sa=1, sn=1, so=1))
    out.append(_fma(s, "deep", "w3m4", 3, 4, "random", 4096, sp=1, sd=1, sa=1, sn=1, so=1))
    out.append(_fma(s, "deep", "w6m18", 6, 18, "random", 1024, sp=1, sd=1, sa=1, sn=1, so=0))
    out.append(_fma(s, "deep", "w6m18_sn2", 6, 18, "random", 1024, sp=1, sd=1, sa=1, sn=2, so=0))
    out.append(_fma(s, "deep", "w8m36", 8, 36, "random", 1024, sp=1, sd=1, sa=1, sn=2, so=0))
    for w, m in [(4, 5), (3, 6), (3, 5), (2, 6)]:
        for si in (0, 1):
            out.append(_binary("div", s, "deep", f"w{w}m{m}", w, m, "exhaustive", 0, si=si))
    for w, m in [(4, 5), (3, 6), (2, 6)]:
        base = f"w{w}m{m}"
        for op in ("abs", "neg", "is_finite", "saturate"):
            out.append(_binary(op, s, "deep", base, w, m, "exhaustive", 0))
        for sd in (0, 1):
            out.append(_binary("mul_ilog2_const", s, "deep", base, w, m, "exhaustive", 0, sd=sd))
    # exp2/log2 coverage: cheapest exhaustive WMAN=16 formats toggle the ROM/Horner; the so=1 run covers the
    # registered pack output, and the sp=2/3/4 runs toggle the shared _zkf_pmul split-product paths via the Horner
    # multiply. The split-final row exercises log2's independent final f*C(f) multiply staging.
    for w, m in [(2, 16), (3, 16)]:
        for op in ("exp2", "log2"):
            out.append(_trans(op, s, "deep", f"w{w}m{m}", w, m, "exhaustive", 0))
    out.append(_trans("exp2", s, "deep", "w2m16", 2, 16, "exhaustive", 0, so=1))
    out.append(_trans("exp2", s, "deep", "w2m16", 2, 16, "exhaustive", 0, sr=1))
    out.append(_trans("log2", s, "deep", "w2m16", 2, 16, "exhaustive", 0, so=1))
    for sp in (2, 3, 4):
        out.append(_trans("exp2", s, "deep", "w3m16", 3, 16, "exhaustive", 0, sp=sp))
        out.append(_trans("log2", s, "deep", "w3m16", 3, 16, "exhaustive", 0, sp=sp))
    out.append(_trans("log2", s, "deep", "w3m16_split_final", 3, 16, "exhaustive", 0, sp=2, spf=3))
    # Wide-format split-product coverage (bona fide, not suppression): the w3m16 sp=2/3/4 rows above instrument the
    # shared _zkf_pmul g_flat/g_rows/g_rows2 reduction trees, but their bounded products leave the high accumulator
    # bits (csum/r_p/rowc/s_row/s_col MSB region) dark. The w8m36 products fill the full WP, so those bits toggle to
    # full width. exp2 drives the unsigned grids, log2 the signed grids (matches the known-good icarus _deep_correctness
    # w8m36 rows). These also widen exp2/log2's significand so its hidden-bit MSB becomes an ordinary toggling bit.
    for sp in (2, 3, 4):
        out.append(_trans("exp2", s, "deep", "w8m36_grid", 8, 36, "random", 512, sp=sp, wm=18))
    for sp in (3, 4):
        out.append(_trans("log2", s, "deep", "w8m36_grid", 8, 36, "random", 512, sp=sp, wm=18))
    # sincos keeps WMAN=11 coverage via the CORDIC table family. It also runs w5_m11 so the tiny-input bypass
    # (e <= -(GUARD_FF+2), only reached once the exponent field is wide enough) toggles too.
    for w, m in [(2, 11), (3, 11)]:
        out.append(_trans("sincos", s, "deep", f"w{w}m{m}", w, m, "exhaustive", 0))
    # sincos: exhaustive w5_m11 reaches the bypass path; un=200 and sn=1/pa=1 cover its UNROLL100 throughput knob
    # and the shared fixed-to-float normshift-barrier / pack-register toggles.
    out.append(_trans("sincos", s, "deep", "w5m11", 5, 11, "exhaustive", 0))
    out.append(_trans("sincos", s, "deep", "w5m11", 5, 11, "exhaustive", 0, un=200))
    out.append(_trans("sincos", s, "deep", "w5m11", 5, 11, "exhaustive", 0, sn=1, pa=1))
    # Lock-step (DECOUPLE=0, un=50) and decoupled (PARALLEL=1, par1) sincos together exercise the line+branch of BOTH
    # CORDIC handoff modes -- the coupled g_zadv path and the half-rate sigma-replay engine. Keep both: each mode's
    # branches (and the phi_seen if/else legs) are reachable only in its own row. The structurally-dead P_PHI
    # implicit-else and FSM default arm are coverage_off in zkf_sincos.v.
    out.append(_trans("sincos", s, "deep", "w5m11", 5, 11, "exhaustive", 0, un=50))
    out.append(_trans("sincos", s, "deep", "w5m11_par1", 5, 11, "exhaustive", 0, un=50, parallel=1))
    # Wide-format sincos (bona fide): at w5m11 the CORDIC X/Y carry / local-magnitude / local-exponent high bits sit
    # above the format ceiling (guard bits above XF, or a magnitude/exponent the narrow datapath never reaches). The
    # w8m24 CORDIC (table _zkf_cordic_m24) makes them ordinary mid-bits the random phase stream toggles, covering
    # cd_xn/e_xn/b2_cos, sin/cos_loc_mag, sin/cos_mag, sh_mag and the loc/cos exponent high bits.
    out.append(_trans("sincos", s, "deep", "w8m24", 8, 24, "random", 768))
    # zkf_atan2 coverage: random + the directed pair table at the cheap 5/11 format reach the small-ratio bypass,
    # the residual divide, and every special/axis/diagonal pair; un=200 and sn/pa toggle the throughput and back-end
    # staging.
    # (Joint-exhaustive is infeasible for a two-input op even at the minimum WMAN, so coverage is random + directed.)
    out.append(_trans("atan2", s, "deep", "atan2_w5m11", 5, 11, "random", 4000))
    out.append(_trans("atan2", s, "deep", "atan2_w5m11_directed", 5, 11, "directed", 0))
    out.append(_trans("atan2", s, "deep", "atan2_w5m11", 5, 11, "random", 2000, un=200))
    out.append(_trans("atan2", s, "deep", "atan2_w5m11", 5, 11, "random", 2000, sn=1, pa=1))
    # Wide-format atan2 (bona fide): at w5m11 the divider/shamt/significand/magnitude high bits sit above the format
    # ceiling (e.g. bit 10 is the significand hidden bit and bit 15 the magnitude sign only because WMAN=11/WFULL=16).
    # At w8m24 those become ordinary mid-bits the random stream toggles, covering d_shamt[5], dv_den/dv_rem/dv_den3, and
    # the be/d significand and output-magnitude high bits -- so they need no suppression. (Replaces a w5m11 "resdiv" row
    # that could not reach them.)
    out.append(_trans("atan2", s, "deep", "atan2_w8m24", 8, 24, "random", 4000))
    for cfg, w, n in [("w8_n2", 8, 2), ("w8_n4", 8, 4), ("w24_n3", 24, 3)]:
        out.append(_pipe(s, "deep", cfg, w, n, 96))
    # w56s1 is a wide directed sweep: its one-hot/low-magnitude vectors drive the full leading-zero-count range, so the
    # high count bits, the split digit registers, and the top-level z3 detect (whose group only fits for W>=49) toggle.
    # w130s1 pushes the internal radix-4 count to its top bit: CNTW = 8 only for clog2(W) in {7,8}, and a count of
    # W-1 = 129 (the one-hot at bit 0) sets cnt[7], which no narrower W and no embedded instance (all count < 128) can.
    # STAGE_OUTPUT sweep (output register + the streaming out_valid/sb_out path) and the standalone STAGE_SPLIT=2 path
    # (w32s2*, NL4>=3) which only the wide log2 back-end exercised end-to-end before. The bench drives in_valid/sb_in
    # and checks out_valid/sb_out are delayed by STAGE_SPLIT + STAGE_OUTPUT.
    for cfg, w, split, output, kind in [("w8s0", 8, 0, 0, "exhaustive"), ("w8s1", 8, 1, 0, "exhaustive"),
                                        ("w9s1", 9, 1, 0, "exhaustive"), ("w32s1", 32, 1, 0, "directed"),
                                        ("w56s1", 56, 1, 0, "directed"), ("w130s1", 130, 1, 0, "directed"),
                                        ("w8s0o1", 8, 0, 1, "exhaustive"), ("w8s1o1", 8, 1, 1, "exhaustive"),
                                        ("w32s2o0", 32, 2, 0, "directed"), ("w32s2o1", 32, 2, 1, "directed")]:
        out.append(_run("normshift", s, "deep", cfg,
                        [("W", w), ("STAGE_SPLIT", split), ("STAGE_OUTPUT", output)], kind=kind, count=0,
                        plus_names={"W": "ZKF_NS_W", "STAGE_SPLIT": "ZKF_NS_SPLIT", "STAGE_OUTPUT": "ZKF_NS_OUTPUT"}))
    for cfg, w, split, kind in [("w8s0", 8, 0, "exhaustive"), ("w8s1", 8, 1, "exhaustive"),
                                ("w16s0", 16, 0, "directed"), ("w16s1", 16, 1, "directed")]:
        out.append(_run("rshift", s, "deep", cfg, [("W", w), ("STAGE_SPLIT", split)], kind=kind, count=0,
                        plus_names={"W": "ZKF_RSH_W", "STAGE_SPLIT": "ZKF_RSH_SPLIT"}))
    for w, m, u in [(4, 5, 6), (4, 5, 7), (3, 6, 5), (4, 4, 6)]:
        out.append(_pack(s, "deep", f"w{w}m{m}u{u}", w, m, u, "exhaustive", 0))
    for w, m, i in [(4, 5, 7), (4, 6, 5), (3, 6, 4), (5, 4, 8)]:
        for si in (0, 1):
            out.append(_cast("to_int", s, "deep", f"w{w}m{m}i{i}", w, m, i, "exhaustive", 0, si))
            out.append(_cast("from_int", s, "deep", f"w{w}m{m}i{i}", w, m, i, "exhaustive", 0, si))
    for wi, mi, wo, mo in [(3, 4, 5, 6), (5, 6, 3, 4), (4, 5, 4, 4), (4, 4, 4, 5), (5, 4, 3, 6), (3, 6, 5, 4)]:
        for si in (0, 1):
            out.append(_resize(s, "deep", f"w{wi}m{mi}_to_w{wo}m{mo}", wi, mi, wo, mo, "exhaustive", 0, si))
    # round coverage: cheap exhaustive formats toggle the rounder and the specials path (w2_m4 reaches the
    # round-up overflow); the all-on knob run toggles the input/pack/output registers; the wide w8_m36 random run
    # toggles the wide boundary-mask decoder and exponent-difference bits the tiny formats cannot reach.
    for w, m in [(2, 4), (4, 5), (3, 6)]:
        out.append(_round(s, "deep", f"w{w}m{m}", w, m, "exhaustive", 0))
    out.append(_round(s, "deep", "w4m5_maxpipe", 4, 5, "exhaustive", 0, si=1, pa=1, so=1))
    out.append(_round(s, "deep", "w8m36", 8, 36, "random", 1024))
    # STAGE_OUTPUT=1 / EXP_IS_BIASED=1 elaborate branches that stay dark under the defaults, so the merged gate can
    # measure them: _zkf_pack g_out_reg (every packer op), zkf_pipe g_registered (div, via _zkf_pack_delay),
    # zkf_resize g_owr (widen path), and the standalone packer's registered-output and biased-exponent cones. One
    # config per branch suffices under merged-union; small exhaustive formats toggle the new registers.
    out.append(_binary("mul", s, "deep", "w3m5", 3, 5, "exhaustive", 0, sp=0, so=1))
    out.append(_binary("add", s, "deep", "w3m5", 3, 5, "exhaustive", 0, sd=0, sa=0, so=1))
    out.append(_binary("addsub", s, "deep", "w3m5", 3, 5, "exhaustive", 0, sd=1, sa=1, so=1))
    out.append(_binary("div", s, "deep", "w3m5", 3, 5, "exhaustive", 0, si=0, so=1))
    out.append(_cast("from_int", s, "deep", "w4m5i7", 4, 5, 7, "exhaustive", 0, 0, so=1))
    # Identity widen (FRAC_PAD=0, BIAS_OFFSET=0) so the registered s_y has no structurally-zero padding bits and every
    # bit toggles under the exhaustive input sweep; a padding-bearing widen would leave low s_y bits permanently 0.
    out.append(_resize(s, "deep", "w4m5_to_w4m5", 4, 5, 4, 5, "exhaustive", 0, 0, so=1))   # widen-only -> g_owr
    out.append(_resize(s, "deep", "w5m6_to_w3m4", 5, 6, 3, 4, "exhaustive", 0, 0, so=1))   # narrow -> g_out_reg
    out.append(_pack(s, "deep", "w4m5u6", 4, 5, 6, "exhaustive", 0, so=1))
    out.append(_pack(s, "deep", "w4m5u6", 4, 5, 6, "exhaustive", 0, eb=1))
    # ASSUME_NO_OVERFLOW=1 prunes the overflow detector (exp_overflow forced to a constant 0). This config regresses
    # the pruned-mode datapath: the case generator drops out-of-range exponents (the caller-undefined region), so the
    # surviving in-range / force_inf / round-carry cases must still match the overflow-detecting reference exactly.
    out.append(_pack(s, "deep", "w4m5u6", 4, 5, 6, "exhaustive", 0, nov=1))


def _properties(out: list) -> None:
    s = "icarus"
    for op in ("add", "addsub"):
        tgt = f"sim_properties_{op}_icarus"
        for sd in (0, 1):
            for sa in (0, 1):
                for cfg, w, m, k, c in BINARY:
                    out.append(_binary(op, s, "properties", cfg, w, m, k, c, sd=sd, sa=sa,
                                       target=tgt, root_module=op))
    for sp in (0, 1):
        for cfg, w, m, k, c in BINARY:
            out.append(_binary("mul", s, "properties", cfg, w, m, k, c, sp=sp,
                               target="sim_properties_mul_icarus", root_module="mul"))


# Smoke set (formerly verify-float-fast): (name, module, extra-vlog).
_FAST = [
    ("pack", "pack", [("WEXP", 2), ("WMAN", 4), ("WEXP_UNBIASED", 4)]),
    ("cmp", "cmp", [("WEXP", 2), ("WMAN", 4)]),
    ("sort", "sort", [("WEXP", 2), ("WMAN", 4)]),
    ("abs", "abs", [("WEXP", 2), ("WMAN", 4)]),
    ("neg", "neg", [("WEXP", 2), ("WMAN", 4)]),
    ("is_finite", "is_finite", [("WEXP", 2), ("WMAN", 4)]),
    ("saturate", "saturate", [("WEXP", 2), ("WMAN", 4)]),
    ("add_sd0_sa0", "add", [("WEXP", 2), ("WMAN", 4), ("STAGE_DECODE", 0), ("STAGE_ALIGN", 0)]),
    ("add_sd1_sa1", "add", [("WEXP", 2), ("WMAN", 4), ("STAGE_DECODE", 1), ("STAGE_ALIGN", 1)]),
    ("addsub_sd0_sa0", "addsub", [("WEXP", 2), ("WMAN", 4), ("STAGE_DECODE", 0), ("STAGE_ALIGN", 0)]),
    ("addsub_sd1_sa1", "addsub", [("WEXP", 2), ("WMAN", 4), ("STAGE_DECODE", 1), ("STAGE_ALIGN", 1)]),
    ("ilog2_sd0", "mul_ilog2_const", [("WEXP", 2), ("WMAN", 4), ("STAGE_DECODE", 0)]),
    ("ilog2_sd1", "mul_ilog2_const", [("WEXP", 2), ("WMAN", 4), ("STAGE_DECODE", 1)]),
    ("mul_sp0", "mul", [("WEXP", 2), ("WMAN", 4), ("STAGE_PRODUCT", 0)]),
    ("mul_sp1", "mul", [("WEXP", 2), ("WMAN", 4), ("STAGE_PRODUCT", 1)]),
    ("mul_so1", "mul", [("WEXP", 2), ("WMAN", 4), ("STAGE_OUTPUT", 1)]),
    ("mul_si1", "mul", [("WEXP", 2), ("WMAN", 4), ("STAGE_INPUT", 1)]),
    ("div_si0", "div", [("WEXP", 2), ("WMAN", 4), ("STAGE_INPUT", 0)]),
    ("div_si1", "div", [("WEXP", 2), ("WMAN", 4), ("STAGE_INPUT", 1)]),
    ("from_int_si0", "from_int", [("WEXP", 2), ("WMAN", 4), ("WINT", 4), ("STAGE_INPUT", 0)]),
    ("from_int_si1", "from_int", [("WEXP", 2), ("WMAN", 4), ("WINT", 4), ("STAGE_INPUT", 1)]),
    ("to_int_si0", "to_int", [("WEXP", 2), ("WMAN", 4), ("WINT", 4), ("STAGE_INPUT", 0)]),
    ("to_int_si1", "to_int", [("WEXP", 2), ("WMAN", 4), ("WINT", 4), ("STAGE_INPUT", 1)]),
    ("resize_si0", "resize", [("WEXP_IN", 3), ("WMAN_IN", 4), ("WEXP_OUT", 3), ("WMAN_OUT", 4), ("STAGE_INPUT", 0)]),
    ("resize_si1", "resize", [("WEXP_IN", 3), ("WMAN_IN", 4), ("WEXP_OUT", 3), ("WMAN_OUT", 4), ("STAGE_INPUT", 1)]),
    ("exp2", "exp2", [("WEXP", 2), ("WMAN", 16), ("STAGE_OUTPUT", 0)]),
    ("log2", "log2", [("WEXP", 2), ("WMAN", 16), ("STAGE_OUTPUT", 0)]),
    ("sincos", "sincos", [("WEXP", 2), ("WMAN", 11), ("UNROLL100", 50)]),
]


def _fast(out: list) -> None:
    for name, module, vlog in _FAST:
        out.append(_run(module, "icarus", "fast", name, vlog, kind="exhaustive", count=0))
    # zkf_atan2 is two-input, so joint-exhaustive is infeasible; the smoke uses the directed special/axis/diagonal
    # pairs.
    out.append(_run("atan2", "icarus", "fast", "atan2",
                    [("WEXP", 5), ("WMAN", 11), ("UNROLL100", 50)], kind="directed", count=0))


def build_matrix() -> list:
    """The complete suite as a flat list of Runs."""
    out: list = []
    _per_pr("icarus", out)
    _per_pr("verilator", out)
    _deep_correctness(out)
    _deep_coverage(out)
    _properties(out)
    _fast(out)
    return out


if __name__ == "__main__":
    import sys
    from collections import Counter

    runs = build_matrix()
    if "--list" in sys.argv:
        for r in sorted(runs, key=lambda r: r.id):
            print(r.id, "->", r.target, r.root)
    counts = Counter((r.tier, r.sim) for r in runs)
    print("counts per (tier, sim):")
    for key in sorted(counts):
        print(f"  {key[0]:11s} {key[1]:9s} {counts[key]}")
    print(f"  {'TOTAL':11s} {'':9s} {len(runs)}")
    ids = [r.id for r in runs]
    dups = [i for i, n in Counter(ids).items() if n > 1]
    print("duplicate ids:", dups if dups else "none")
