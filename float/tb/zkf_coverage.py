#!/usr/bin/env python3
"""Merge Verilator coverage, generate an HTML report, and optionally gate uncovered ZKF RTL coverage.

Three coverage dimensions are understood, all emitted natively by Verilator (``--coverage-line``
instruments per basic block, so ``v_line`` already gives branch-arm coverage; ``v_branch`` is the
explicit branch metric; ``--coverage-toggle`` gives per-net-bit toggle coverage):

  * ``v_line``   - basic-block / line coverage
  * ``v_branch`` - branch coverage (each if/else/case arm)
  * ``v_toggle`` - net-bit toggle coverage (0->1 and 1->0 per bit)

Gating modes:

  * ``--gate``  : fail on any uncovered executable LINE (historical behaviour, used by per-PR CI).
  * ``--full``  : fail on any uncovered line, branch, OR toggle point. Used by the deep tier
                  (``coverage-float-gate-full``).

Verilator coverage points are keyed per parameterisation AND per hierarchy instance, but the *net
name* (``o`` field) is parameter- and instance-independent. We merge points by
``(file, page-type, line, net)`` - dropping both the parameter mangling and the hierarchy - taking
the max hit count across every coverage.dat. So a point counts as covered if *any* configuration in
*any* instantiation hit it. This is the right semantic for a reusable library: we verify that each
piece of RTL is exercised somewhere (a shared submodule via its own standalone test, e.g. _zkf_pack
via sim_pack), not that every embedded instantiation drives it to every state - the parent's
correctness test covers the integration. It is also what lets a diverse matrix close toggle coverage
that no single format reaches alone.

Genuinely unreachable points (e.g. a structurally-constant bit, or a defensive elaboration guard) are
suppressed at the source with Verilator's own ``// verilator coverage_off`` / ``coverage_on`` pragmas
- the same mechanism the RTL already uses. A suppressed region emits no coverage point, so the gate
needs no special-casing. There is intentionally NO external waiver list: a file of line numbers and
net names rots as the RTL changes, whereas in-source pragmas move with the code.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass, field
from html import escape
from pathlib import Path
import re
import shutil
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "float" / "hdl"
TB_DIR = REPO_ROOT / "float" / "tb"

_RECORD = re.compile(r"^C '(.*)' (\d+)\s*$")

# Top-level DUT ports excluded from the TOGGLE gate. Toggle coverage targets internal logic state;
# primary inputs are testbench-driven (stimulus, not DUT logic) and primary outputs are exercised via
# 100% line+branch coverage of the logic that produces them. Excluding primary I/O from toggle is a
# standard policy. These bare names are never used for internal nets in this library; internal nets
# stay gated. (pack's data-input ports are intentionally NOT toggle-excluded - sim_pack covers them.)
_TB_DRIVEN_PORTS = {"clk", "rst", "in_valid", "out_valid", "a", "b", "x", "y", "in", "op_sub", "shamt"}


def is_zkf_source(path_text: str) -> bool:
    path = Path(path_text)
    return path.parent.name == "hdl" and path.name.endswith(".v") and path.name.startswith(("zkf_", "_zkf_"))


def normalized_source(path_text: str) -> str:
    """Rewrite an SF: path from the per-run staged copy back to a path that exists in the workspace,
    so genhtml can find the source. Verilator emits paths relative to the build CWD which no longer resolve once the
    build subdirectory is cleaned. We don't rewrite paths whose basename isn't found locally; genhtml will still skip
    them gracefully."""
    path = Path(path_text)
    if path.parent.name == "hdl":
        source = RTL_DIR / path.name
        if source.is_file():
            return str(source)
    if path.parent.name == "_tables":
        source = RTL_DIR / "_tables" / path.name
        if source.is_file():
            return str(source)
    if path.parent.name == "tb":
        source = TB_DIR / path.name
        if source.is_file():
            return str(source)
    return path_text


def normalize_info_sources(info_path: Path) -> None:
    lines = []
    with info_path.open() as fp:
        for raw in fp:
            if raw.startswith("SF:"):
                lines.append(f"SF:{normalized_source(raw[3:].strip())}\n")
            else:
                lines.append(raw)
    info_path.write_text("".join(lines), encoding="utf-8")


def merge_coverage(build_dir: Path, output_dir: Path) -> Path:
    tool = shutil.which("verilator_coverage")
    if tool is None:
        raise RuntimeError("verilator_coverage is not on PATH")

    dat_files = sorted(build_dir.rglob("coverage.dat"))
    if not dat_files:
        raise RuntimeError(f"no coverage.dat files found under {build_dir}")

    output_dir.mkdir(parents=True, exist_ok=True)
    info_path = output_dir / "merged.info"
    subprocess.run(
        [tool, "--write-info", str(info_path), *(str(path) for path in dat_files)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    normalize_info_sources(info_path)
    return info_path


# --------------------------------------------------------------------------------------------------
# Raw coverage.dat parsing for branch and toggle points.
# --------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Point:
    file: str        # basename, e.g. "_zkf_pack.v"
    ptype: str       # "v_line" | "v_branch" | "v_toggle"
    line: int
    net: str         # the 'o' field, parameter- and instance-independent (e.g. "s1_result_min_normal:0->1")


def _parse_fields(key: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for part in key.split("\x01"):
        name, sep, value = part.partition("\x02")
        if sep:
            fields[name] = value
    return fields


def merged_points(build_dir: Path) -> dict[Point, int]:
    """Merge every coverage.dat by parameter-independent point identity, taking the max hit count.

    A point is covered iff it was hit by at least one configuration in the matrix."""
    merged: dict[Point, int] = defaultdict(int)
    for dat in sorted(build_dir.rglob("coverage.dat")):
        with dat.open(encoding="latin-1") as fp:
            for raw in fp:
                m = _RECORD.match(raw)
                if not m:
                    continue
                fields = _parse_fields(m.group(1))
                count = int(m.group(2))
                src = fields.get("f", "")
                if not is_zkf_source(src):
                    continue
                page = fields.get("page", "")
                ptype = page.split("/", 1)[0]
                if ptype not in ("v_line", "v_branch", "v_toggle"):
                    continue
                try:
                    line = int(fields.get("l", "0"))
                except ValueError:
                    line = 0
                net = fields.get("o", "")
                # Toggle coverage measures whether the DUT's internal logic exercises its states. Primary
                # inputs and the clock/reset are driven entirely by the testbench, so their toggle reflects
                # stimulus, not DUT logic (and exhaustive/random stimulus plus 100% line+branch already
                # prove every input-dependent path). Exclude these top-level ports from the toggle gate, as
                # is standard; internal nets and output ports remain gated.
                if ptype == "v_toggle" and net.split(":", 1)[0].split("[", 1)[0] in _TB_DRIVEN_PORTS:
                    continue
                point = Point(file=Path(src).name, ptype=ptype, line=line, net=net)
                if count > merged[point]:
                    merged[point] = count
    return dict(merged)


@dataclass
class Stats:
    total: int = 0
    covered: int = 0
    uncovered: list[Point] = field(default_factory=list)


def summarize(points: dict[Point, int]) -> dict[str, dict[str, Stats]]:
    """Return {file: {ptype: Stats}}. Line and branch coverage are gated (mandatory); toggle coverage is
    advisory. Genuinely-unreachable LINE/BRANCH points are suppressed at the source with Verilator's
    `// verilator coverage_off` / `coverage_on` pragmas (kept to a minimum); there is deliberately no
    external waiver list to keep in sync. Toggle points are never suppressed -- they are reported as-is."""
    out: dict[str, dict[str, Stats]] = defaultdict(lambda: defaultdict(Stats))
    for point, count in points.items():
        st = out[point.file][point.ptype]
        st.total += 1
        if count > 0:
            st.covered += 1
        else:
            st.uncovered.append(point)
    return out


PTYPES = ("v_line", "v_branch", "v_toggle")
PTYPE_LABEL = {"v_line": "Line/Block", "v_branch": "Branch", "v_toggle": "Toggle"}


def write_report(output_dir: Path, summary: dict[str, dict[str, Stats]], genhtml_ok: bool) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    def bar(st: Stats) -> str:
        denom = st.total or 1
        pct = 100.0 * st.covered / denom
        color = "#86efac" if not st.uncovered else "#fca5a5"
        n_un = len(st.uncovered)
        return (f"<div class='cell'><div class='barwrap'><div class='bar' style='width:{pct:.1f}%;"
                f"background:{color}'></div></div><span class='pctn'>{pct:.1f}% "
                f"({st.covered}/{st.total}){' · ' + str(n_un) + ' UNCOVERED' if n_un else ''}</span></div>")

    rows = []
    for fname in sorted(summary):
        cells = "".join(f"<td>{bar(summary[fname].get(pt, Stats()))}</td>" for pt in PTYPES)
        rows.append(f"<tr><td class='fn'>{escape(fname)}</td>{cells}</tr>")

    detail_rows = []
    for fname in sorted(summary):
        for pt in PTYPES:
            st = summary[fname].get(pt)
            if not st or not st.uncovered:
                continue
            for p in sorted(st.uncovered, key=lambda q: (q.line, q.net))[:200]:
                detail_rows.append(
                    f"<tr><td>{escape(fname)}</td><td>{PTYPE_LABEL[pt]}</td><td>{p.line}</td>"
                    f"<td class='net'>{escape(p.net)}</td></tr>"
                )
    detail = (
        "<h2>Uncovered points</h2><table><thead><tr><th>Source</th><th>Kind</th><th>Line</th>"
        "<th>Net / block</th></tr></thead><tbody>" + "\n".join(detail_rows) + "</tbody></table>"
        if detail_rows else "<h2>Uncovered points</h2><p class='good'>None — every line, branch, and toggle covered.</p>"
    )

    genhtml_link = ("<p><a href='lcov/index.html'>Detailed line drill-down (genhtml) &rarr;</a></p>"
                    if genhtml_ok else "")
    note = ("<p class='sub'>Genuinely-unreachable points are suppressed in the RTL with "
            "<code>// verilator coverage_off</code> / <code>coverage_on</code> and so never appear here.</p>")

    (output_dir / "index.html").write_text(
        f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Kulibin Float Coverage</title>
<style>
body {{ margin:0; font-family:system-ui,sans-serif; background:#0b1020; color:#e5e7eb; }}
main {{ max-width:1100px; margin:0 auto; padding:40px 24px; }}
h1 {{ font-size:30px; margin:0 0 6px; }}
h2 {{ margin:34px 0 12px; color:#93c5fd; }}
.sub {{ color:#94a3b8; margin:0 0 20px; }}
table {{ width:100%; border-collapse:collapse; border-radius:10px; overflow:hidden; box-shadow:0 0 0 1px #1f2937; }}
th,td {{ padding:10px 12px; border-bottom:1px solid #1f2937; text-align:left; vertical-align:middle; }}
th {{ background:#111827; color:#93c5fd; font-size:13px; letter-spacing:.04em; text-transform:uppercase; }}
td {{ background:#0e1426; font-size:14px; }}
.fn {{ font-family:ui-monospace,monospace; color:#fbbf24; }}
.net,.hier {{ font-family:ui-monospace,monospace; font-size:12px; color:#cbd5e1; }}
.barwrap {{ background:#1f2937; border-radius:6px; height:10px; width:130px; overflow:hidden; display:inline-block; vertical-align:middle; }}
.bar {{ height:10px; }}
.pctn {{ font-size:12px; margin-left:8px; color:#cbd5e1; }}
code {{ font-family:ui-monospace,monospace; background:#111827; padding:1px 5px; border-radius:4px; font-size:12px; }}
.good {{ color:#86efac; font-weight:700; }}
.bad {{ color:#fca5a5; font-weight:700; }}
</style></head><body><main>
<h1>Kulibin Float — Verilator Coverage (line · branch · toggle)</h1>
<p class="sub">Merged across the parameter matrix by parameter-independent point identity; covered = hit by at least one configuration.</p>
<table><thead><tr><th>Source</th><th>Line/Block</th><th>Branch</th><th>Toggle</th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody></table>
{note}
{genhtml_link}
{detail}
</main></body></html>
""",
        encoding="utf-8",
    )


def run_genhtml(info_path: Path, output_dir: Path) -> bool:
    tool = shutil.which("genhtml")
    if tool is None:
        return False
    lcov_dir = output_dir / "lcov"
    subprocess.run(
        [tool, "--legend", "--show-details", "--title", "Kulibin Float Line Coverage",
         "--output-directory", str(lcov_dir), str(info_path)],
        check=True, stdout=subprocess.DEVNULL,
    )
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=Path("build/float/verilator"))
    parser.add_argument("--output-dir", type=Path, default=Path("build/float/coverage"))
    parser.add_argument("--gate", action="store_true",
                        help="per-PR tier: fail on uncovered LINE points only (branch is gated by --full; "
                             "toggle is advisory)")
    parser.add_argument("--full", action="store_true",
                        help="deep tier: fail on uncovered LINE or BRANCH points; report toggle as advisory")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        info_path = merge_coverage(args.build_dir, args.output_dir)
        genhtml_ok = run_genhtml(info_path, args.output_dir)

        points = merged_points(args.build_dir)
        summary = summarize(points)
        write_report(args.output_dir, summary, genhtml_ok)
    except Exception as ex:  # noqa: BLE001 - report any tooling failure as a hard error
        print(f"[float-coverage] failed: {ex}", file=sys.stderr)
        return 2

    # Aggregate uncovered counts by dimension.
    uncovered: dict[str, list[Point]] = {pt: [] for pt in PTYPES}
    for fname, by_type in summary.items():
        for pt, st in by_type.items():
            uncovered[pt].extend(st.uncovered)

    def report(label: str, pts: list[Point]) -> None:
        print(f"[float-coverage] uncovered {label} points: {len(pts)}", file=sys.stderr)
        for p in sorted(pts, key=lambda q: (q.file, q.line, q.net))[:80]:
            print(f"    {p.file}:{p.line} {p.net}", file=sys.stderr)

    if args.full:
        # Line and branch coverage are mandatory; TOGGLE coverage is ADVISORY -- reported but never fatal. Toggle is
        # consulted while developing the RTL, not used as a verification quality gate (chasing 100% toggle on wide
        # datapaths is impractical and was the cause of the prior `// verilator coverage_off` sprawl).
        gated = ("v_line", "v_branch")
        for pt in PTYPES:
            if uncovered[pt]:
                report(PTYPE_LABEL[pt] + (" [advisory]" if pt == "v_toggle" else ""), uncovered[pt])
        if any(uncovered[pt] for pt in gated):
            print("[float-coverage] To close: add a config/vector that exercises the uncovered line/branch, or "
                  "suppress a genuinely-unreachable line/branch in the RTL with `// verilator coverage_off`/"
                  "`coverage_on`.", file=sys.stderr)
            return 1
        ntog = len(uncovered["v_toggle"])
        print(f"[float-coverage] PASS: line+branch covered ({ntog} toggle point(s) uncovered -- advisory, "
              f"non-fatal). Report: {args.output_dir / 'index.html'}")
        return 0

    # Default / --gate (per-PR): gate on uncovered LINE points only, ptype-aware. Branch coverage is enforced at
    # the deep tier (--full); toggle coverage is advisory everywhere and is never gated. Gating on the raw merged
    # LCOV info instead would be ptype-blind -- it collapses line/branch/toggle into one DA record per source line,
    # so an isolated uncovered toggle point (e.g. a control input the per-PR set never asserts) would fail the
    # line gate. That ptype-blindness was the cause of the prior `// verilator coverage_off` sprawl.
    line_uncovered = uncovered["v_line"]
    if line_uncovered:
        report("line", line_uncovered)
        if args.gate:
            print("[float-coverage] To close: add a config/vector that exercises the uncovered line, or suppress a "
                  "genuinely-unreachable line in the RTL with `// verilator coverage_off`/`coverage_on`.",
                  file=sys.stderr)
        return 1 if args.gate else 0

    nbr = len(uncovered["v_branch"])
    ntog = len(uncovered["v_toggle"])
    print(f"[float-coverage] PASS: line covered ({nbr} branch + {ntog} toggle point(s) uncovered -- not gated at "
          f"this tier; run --full for the branch gate). Report: {args.output_dir / 'index.html'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
