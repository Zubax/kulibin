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
         target=None, with_kind=True, plus_names=None, root_module=None) -> Run:
    """Assemble one Run. vlog params are mirrored to plusargs as ZKF_<name> unless plus_names overrides."""
    plus_names = plus_names or {}
    plus = [(plus_names.get(name, "ZKF_" + name), val) for name, val in vlog]
    plus += _common(kind, count, config, with_kind=with_kind)
    target = target or f"sim_{module}_{sim}"
    root = _root(tier, sim, root_module or module, config)
    return Run(module, sim, tier, config, target, root, vlog, plus)


# --- builders that mirror the former bash helpers -------------------------------------------------
def _binary(module, sim, tier, base, w, m, kind, count, *, sp=None, si=None, sd=None, sa=None,
            so=None, target=None, root_module=None) -> Run:
    vlog = [("WEXP", w), ("WMAN", m)]
    suffix = ""
    if sp is not None:
        vlog.append(("STAGE_PRODUCT", sp)); suffix += f"_sp{sp}"
    if si is not None:
        vlog.append(("STAGE_INPUT", si)); suffix += f"_si{si}"
    if sd is not None and sa is not None:
        vlog += [("STAGE_DECODE", sd), ("STAGE_ALIGN", sa)]; suffix += f"_sd{sd}_sa{sa}"
    elif sd is not None:
        vlog.append(("STAGE_DECODE", sd)); suffix += f"_sd{sd}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run(module, sim, tier, base + suffix, vlog, kind=kind, count=count,
                target=target, root_module=root_module)


def _fma(sim, tier, base, w, m, kind, count, *, sp=None, sd=None, sa=None, sn=None, so=None) -> Run:
    vlog = [("WEXP", w), ("WMAN", m)]
    suffix = ""
    if sp is not None:
        vlog.append(("STAGE_PRODUCT", sp)); suffix += f"_sp{sp}"
    if sd is not None:
        vlog.append(("STAGE_DECODE", sd)); suffix += f"_sd{sd}"
    if sa is not None:
        vlog.append(("STAGE_ALIGN", sa)); suffix += f"_sa{sa}"
    if sn is not None:
        vlog.append(("STAGE_NORMALIZE", sn)); suffix += f"_sn{sn}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run("fma", sim, tier, base + suffix, vlog, kind=kind, count=count)


def _pack(sim, tier, config, w, m, u, kind, count, *, so=None, eb=None) -> Run:
    vlog = [("WEXP", w), ("WMAN", m), ("WEXP_UNBIASED", u)]
    suffix = ""
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    if eb is not None:
        vlog.append(("EXP_IS_BIASED", eb)); suffix += f"_eb{eb}"
    return _run("pack", sim, tier, config + suffix, vlog, kind=kind, count=count)


def _cast(module, sim, tier, base, w, m, wint, kind, count, si, so=None) -> Run:
    vlog = [("WEXP", w), ("WMAN", m), ("WINT", wint), ("STAGE_INPUT", si)]
    suffix = f"_si{si}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run(module, sim, tier, f"{base}{suffix}", vlog, kind=kind, count=count)


def _resize(sim, tier, base, wi, mi, wo, mo, kind, count, si, so=None) -> Run:
    vlog = [("WEXP_IN", wi), ("WMAN_IN", mi), ("WEXP_OUT", wo), ("WMAN_OUT", mo), ("STAGE_INPUT", si)]
    suffix = f"_si{si}"
    if so is not None:
        vlog.append(("STAGE_OUTPUT", so)); suffix += f"_so{so}"
    return _run("resize", sim, tier, f"{base}{suffix}", vlog, kind=kind, count=count)


def _pipe(sim, tier, config, w, n, count) -> Run:
    return _run("pipe", sim, tier, config, [("W", w), ("N", n)], count=count, with_kind=False,
                plus_names={"W": "ZKF_PIPE_W", "N": "ZKF_PIPE_N"})


# --- the matrix -----------------------------------------------------------------------------------
def _per_pr(sim, out: list) -> None:
    for cfg, w, m, u, k, c in PACK:
        out.append(_pack(sim, "pr", cfg, w, m, u, k, c))
    for op in ("cmp", "sort"):
        for cfg, w, m, k, c in BINARY:
            out.append(_binary(op, sim, "pr", cfg, w, m, k, c))
    for op in ("add", "addsub"):
        for sd in (0, 1):
            for sa in (0, 1):
                for cfg, w, m, k, c in BINARY:
                    out.append(_binary(op, sim, "pr", cfg, w, m, k, c, sd=sd, sa=sa))
    for sp in (0, 1):
        for cfg, w, m, k, c in BINARY:
            out.append(_binary("mul", sim, "pr", cfg, w, m, k, c, sp=sp))
    for si in (0, 1):
        for cfg, w, m, k, c in BINARY:
            out.append(_binary("div", sim, "pr", cfg, w, m, k, c, si=si))
    for cfg, w, m, k, c in FMA:
        out.append(_fma(sim, "pr", cfg, w, m, k, c))
    # Each pipeline knob exercised once (plus all-on) on a fast format. Results are staging-independent, so this
    # validates the out_valid timing of every STAGE_* register without re-running the slow formats.
    for sp, sd, sa, sn, so in [(0, 0, 0, 0, 0), (1, 0, 0, 0, 0), (0, 1, 0, 0, 0), (0, 0, 1, 0, 0),
                               (0, 0, 0, 1, 0), (0, 0, 0, 0, 1), (1, 1, 1, 1, 1)]:
        out.append(_fma(sim, "pr", "w4_m6_stage", 4, 6, "random", 256, sp=sp, sd=sd, sa=sa, sn=sn, so=so))
    # STAGE_NORMALIZE=2 (FMA-local 3-segment normalizer) needs NL4 = ($clog2(2*WMAN+3)+1)/2 >= 3, i.e. WMAN >= 7
    # (smaller WMAN collapses its two register barriers and is rejected at elaboration), so it cannot use the w4/m6
    # knob format above. Exercise it at the WMAN=7 guard boundary - the smallest format permitted, and a WINDEX-
    # dominated WEU corner - and at a wider WMAN=18 so CI covers both the guard edge and the +1-stage timing.
    out.append(_fma(sim, "pr", "w4m7_sn2", 4, 7, "random", 384, sp=1, sd=1, sa=1, sn=2))
    out.append(_fma(sim, "pr", "w6m18_sn2", 6, 18, "random", 384, sp=1, sd=1, sa=1, sn=2))
    # The narrow synth/CI config ships as STAGE_PRODUCT=1 + STAGE_NORMALIZE=2 (closes all four W6/M18 datapath cones);
    # gate that exact stage combination so correctness of the shipped config is tested directly, not just inferred.
    out.append(_fma(sim, "pr", "w6m18_sp1_sn2", 6, 18, "random", 384, sp=1, sn=2))
    for op in ("abs", "neg", "is_finite", "saturate"):
        for cfg, w, m, k, c in UNARY:
            out.append(_binary(op, sim, "pr", cfg, w, m, k, c))
    for sd in (0, 1):
        for cfg, w, m, k, c in UNARY:
            out.append(_binary("mul_ilog2_const", sim, "pr", cfg, w, m, k, c, sd=sd))
    for si in (0, 1):
        for cfg, w, m, wint, k, c in FROM_INT:
            out.append(_cast("from_int", sim, "pr", cfg, w, m, wint, k, c, si))
        for cfg, w, m, wint, k, c in TO_INT:
            out.append(_cast("to_int", sim, "pr", cfg, w, m, wint, k, c, si))
        for cfg, wi, mi, wo, mo, k, c in RESIZE:
            out.append(_resize(sim, "pr", cfg, wi, mi, wo, mo, k, c, si))
    out.append(_binary("add", sim, "pr", "w6_m100_directed", 6, 100, "directed", 0))  # one-off
    for cfg, w, n, c in PIPE:
        out.append(_pipe(sim, "pr", cfg, w, n, c))


def _deep_correctness(out: list) -> None:
    # Full Cartesian product of each module's structural knobs, swept across every format in its deep list, so every
    # parameter combination is exercised for correctness. (Coverage closure lives in _deep_coverage under merged-union
    # semantics.) Knob axes: mul = STAGE_PRODUCT x STAGE_OUTPUT; add/addsub = STAGE_DECODE x STAGE_ALIGN x STAGE_OUTPUT;
    # div/from_int/resize = STAGE_INPUT x STAGE_OUTPUT; to_int = STAGE_INPUT only (no STAGE_OUTPUT); pack = STAGE_OUTPUT
    # x EXP_IS_BIASED; mul_ilog2_const = STAGE_DECODE x K (K already fanned out by its wrapper).
    s = "icarus"
    for w, m, k, c in BIN_EXT:
        base = f"w{w}m{m}_{k}"
        for sp in (0, 1):
            for so in (0, 1):
                out.append(_binary("mul", s, "deep", base, w, m, k, c, sp=sp, so=so))
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
        for sd in (0, 1):
            for sa in (0, 1):
                for sn in (0, 1):
                    for so in (0, 1):
                        out.append(_fma(s, "deep", "w4m6_knobs", 4, 6, "random", 256,
                                        sp=sp, sd=sd, sa=sa, sn=sn, so=so))
    out.append(_fma(s, "deep", "w8m36", 8, 36, "random", 768, sp=1, sd=1, sa=1, sn=2))
    for sp, sd, sa, sn, so in ((0, 0, 0, 0, 0), (1, 1, 1, 1, 1)):
        out.append(_fma(s, "deep", "w2m4_exhaustive", 2, 4, "exhaustive", 0, sp=sp, sd=sd, sa=sa, sn=sn, so=so))
    for w, m, k, c in DIV_EXT:
        for si in (0, 1):
            for so in (0, 1):
                out.append(_binary("div", s, "deep", f"w{w}m{m}_{k}", w, m, k, c, si=si, so=so))
    for w, m, k, c in UNARY_EXT:
        base = f"w{w}m{m}_{k}"
        for op in ("abs", "neg", "is_finite", "saturate"):
            out.append(_binary(op, s, "deep", base, w, m, k, c))
        for sd in (0, 1):
            out.append(_binary("mul_ilog2_const", s, "deep", base, w, m, k, c, sd=sd))
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
    for wi, mi, wo, mo, k, c in [(4, 5, 4, 4, "exhaustive", 0), (4, 4, 4, 5, "exhaustive", 0),
                                 (2, 5, 4, 7, "exhaustive", 0), (4, 7, 2, 5, "exhaustive", 0),
                                 (5, 5, 3, 4, "exhaustive", 0), (3, 4, 5, 5, "exhaustive", 0),
                                 (6, 17, 4, 11, "random", 512), (5, 11, 6, 17, "random", 512)]:
        base = f"w{wi}m{mi}_to_w{wo}m{mo}_{k}"
        for si in (0, 1):
            for so in (0, 1):
                out.append(_resize(s, "deep", base, wi, mi, wo, mo, k, c, si, so=so))


def _deep_coverage(out: list) -> None:
    s = "verilator"
    for w, m in [(4, 5), (3, 6), (5, 4), (3, 5), (2, 6)]:
        base = f"w{w}m{m}"
        for sp in (0, 1):
            out.append(_binary("mul", s, "deep", base, w, m, "exhaustive", 0, sp=sp))
        out.append(_binary("add", s, "deep", base, w, m, "exhaustive", 0, sd=0, sa=0))
        out.append(_binary("add", s, "deep", base, w, m, "exhaustive", 0, sd=1, sa=1))
        out.append(_binary("addsub", s, "deep", base, w, m, "exhaustive", 0, sd=1, sa=1))
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
    for cfg, w, n in [("w8_n2", 8, 2), ("w8_n4", 8, 4), ("w24_n3", 24, 3)]:
        out.append(_pipe(s, "deep", cfg, w, n, 96))
    # w56s1 is a wide directed sweep: its one-hot/low-magnitude vectors drive the full leading-zero-count range, so the
    # high count bits, the split digit registers, and the top-level z3 detect (whose group only fits for W>=49) toggle.
    for cfg, w, split, kind in [("w8s0", 8, 0, "exhaustive"), ("w8s1", 8, 1, "exhaustive"),
                                ("w9s1", 9, 1, "exhaustive"), ("w32s1", 32, 1, "directed"),
                                ("w56s1", 56, 1, "directed")]:
        out.append(_run("normshift", s, "deep", cfg, [("W", w), ("STAGE_SPLIT", split)], kind=kind, count=0,
                        plus_names={"W": "ZKF_NS_W", "STAGE_SPLIT": "ZKF_NS_SPLIT"}))
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
    # STAGE_OUTPUT=1 / EXP_IS_BIASED=1 elaborate branches that stay dark under the defaults, so the merged gate can
    # measure them: _zkf_pack g_out_reg (every packer op), _zkf_pack_delay g_reg (div), zkf_resize g_owr (widen path),
    # and the standalone packer's registered-output and biased-exponent cones. One config per branch suffices under
    # merged-union; small exhaustive formats toggle the new registers.
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
    ("div_si0", "div", [("WEXP", 2), ("WMAN", 4), ("STAGE_INPUT", 0)]),
    ("div_si1", "div", [("WEXP", 2), ("WMAN", 4), ("STAGE_INPUT", 1)]),
    ("from_int_si0", "from_int", [("WEXP", 2), ("WMAN", 4), ("WINT", 4), ("STAGE_INPUT", 0)]),
    ("from_int_si1", "from_int", [("WEXP", 2), ("WMAN", 4), ("WINT", 4), ("STAGE_INPUT", 1)]),
    ("to_int_si0", "to_int", [("WEXP", 2), ("WMAN", 4), ("WINT", 4), ("STAGE_INPUT", 0)]),
    ("to_int_si1", "to_int", [("WEXP", 2), ("WMAN", 4), ("WINT", 4), ("STAGE_INPUT", 1)]),
    ("resize_si0", "resize", [("WEXP_IN", 3), ("WMAN_IN", 4), ("WEXP_OUT", 3), ("WMAN_OUT", 4), ("STAGE_INPUT", 0)]),
    ("resize_si1", "resize", [("WEXP_IN", 3), ("WMAN_IN", 4), ("WEXP_OUT", 3), ("WMAN_OUT", 4), ("STAGE_INPUT", 1)]),
]


def _fast(out: list) -> None:
    for name, module, vlog in _FAST:
        out.append(_run(module, "icarus", "fast", name, vlog, kind="exhaustive", count=0))


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
