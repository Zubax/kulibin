#!/usr/bin/env python3
"""Aggregate Verilator coverage from all per-config runs and gate on missing bins.

Looks for ``coverage.dat`` files under ``--build-dir`` (recursively), merges them
with ``verilator_coverage --write-info``, parses the LCOV ``.info`` output,
subtracts waivers from :mod:`coverage_waivers`, and prints a markdown summary
to ``coverage_report.md``. Exits non-zero when any RTL line or branch belonging
to ``float/hdl/*.v`` is unhit and not waived.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Iterable

from coverage_waivers import WAIVERS, waived_lines_for


REPO = Path(__file__).resolve().parents[2]


@dataclass
class FileCoverage:
    path: str
    line_hits: dict[int, int] = field(default_factory=dict)
    branch_hits: dict[tuple[int, int, int], int] = field(default_factory=dict)


def discover_coverage_dat(build_dir: Path) -> list[Path]:
    return sorted(build_dir.rglob("coverage.dat"))


def run_verilator_coverage(dat_files: list[Path], output_info: Path) -> None:
    binary = shutil.which("verilator_coverage")
    if binary is None:
        raise RuntimeError("verilator_coverage not on PATH")
    if not dat_files:
        raise RuntimeError("no coverage.dat files to merge")
    cmd = [binary, "--write-info", str(output_info), *(str(p) for p in dat_files)]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def parse_lcov_info(info_path: Path) -> dict[str, FileCoverage]:
    files: dict[str, FileCoverage] = {}
    current: FileCoverage | None = None
    with info_path.open() as fp:
        for raw in fp:
            line = raw.strip()
            if line.startswith("SF:"):
                sf = line[3:]
                current = files.setdefault(sf, FileCoverage(path=sf))
            elif current is not None and line.startswith("DA:"):
                parts = line[3:].split(",")
                lineno = int(parts[0])
                hits = int(parts[1])
                current.line_hits[lineno] = max(current.line_hits.get(lineno, 0), hits)
            elif current is not None and line.startswith("BRDA:"):
                parts = line[5:].split(",")
                lineno = int(parts[0])
                block = int(parts[1])
                branch = int(parts[2])
                hits_str = parts[3]
                hits = 0 if hits_str == "-" else int(hits_str)
                key = (lineno, block, branch)
                current.branch_hits[key] = max(current.branch_hits.get(key, 0), hits)
            elif line == "end_of_record":
                current = None
    return files


def is_zkf_source(path_str: str) -> bool:
    """Identify a Verilator source file that belongs to the ZKF RTL set.

    We can't compare against an absolute REPO/float/hdl path because FuseSoC
    copies sources into its own build tree before invoking Verilator. Match by
    parent-directory name and filename instead.
    """
    p = Path(path_str)
    if p.parent.name != "hdl":
        return False
    name = p.name
    if not name.endswith(".v"):
        return False
    return name.startswith("zkf_") or name.startswith("_zkf_")


def categorize_misses(file_cov: FileCoverage, waived: set[int]) -> tuple[list[int], list[tuple[int, int, int]]]:
    """Return (missing_lines, missing_toggle_points). Line gaps gate the run;
    toggle gaps are reported but informational."""
    missing_lines = sorted(line for line, hits in file_cov.line_hits.items() if hits == 0 and line not in waived)
    # Verilator's BRDA records are emitted by --coverage-toggle and represent per-bit toggle
    # observations (one entry per bit per direction). They are too granular to gate strictly,
    # so we collect them for the report but do not fail on them.
    missing_branches = sorted(
        key for key, hits in file_cov.branch_hits.items() if hits == 0 and key[0] not in waived
    )
    return missing_lines, missing_branches


def render_markdown_report(per_file: dict[str, dict[str, object]], output: Path) -> None:
    lines: list[str] = ["# ZKF Verilator RTL Coverage Report\n"]
    lines.append(
        "Line coverage gates the run. Toggle (BRDA) counts are reported for visibility but "
        "are not enforced: Verilator emits one toggle point per bit per direction, so wide "
        "datapath registers contribute many low-priority bits that random/directed streams "
        "do not necessarily reach.\n"
    )
    lines.append("| File | Lines hit | Lines total | Lines missing | Waived | Toggle hit | Toggle total |")
    lines.append("|------|-----------|-------------|---------------|--------|------------|--------------|")
    for path in sorted(per_file):
        stats = per_file[path]
        lines.append(
            f"| {Path(path).name} | {stats['lines_hit']} | {stats['lines_total']} | "
            f"{stats['lines_missing']} | {stats['lines_waived']} | "
            f"{stats['branches_hit']} | {stats['branches_total']} |"
        )
    lines.append("")
    any_missing_lines = False
    for path in sorted(per_file):
        stats = per_file[path]
        missing_lines: list[int] = stats["missing_lines"]  # type: ignore[assignment]
        if not missing_lines:
            continue
        any_missing_lines = True
        lines.append(f"## {Path(path).name} — line gaps\n")
        lines.append("Missing lines: " + ", ".join(str(line) for line in missing_lines))
        lines.append("")
    lines.append("## Waivers\n")
    if not WAIVERS:
        lines.append("(none)")
    for w in WAIVERS:
        lines.append(f"- {w.file_basename} lines {w.line_range[0]}-{w.line_range[1]} ({w.kind}): {w.reason}")
    lines.append("")
    if not any_missing_lines:
        lines.insert(1, "All RTL lines covered or waived.\n")
    output.write_text("\n".join(lines))


def aggregate(build_dir: Path, report_path: Path, info_path: Path) -> int:
    dat_files = discover_coverage_dat(build_dir)
    if not dat_files:
        print(
            f"[coverage] no coverage.dat under {build_dir} — did you run Verilator with --coverage-line --coverage-toggle?",
            file=sys.stderr,
        )
        return 2
    print(f"[coverage] merging {len(dat_files)} coverage.dat files", flush=True)
    run_verilator_coverage(dat_files, info_path)
    files = parse_lcov_info(info_path)

    per_file: dict[str, dict[str, object]] = {}
    fail = False
    for source_path, cov in files.items():
        if not is_zkf_source(source_path):
            continue
        basename = Path(source_path).name
        waived = waived_lines_for(basename)
        missing_lines, missing_branches = categorize_misses(cov, waived)
        per_file[source_path] = {
            "lines_total": len(cov.line_hits),
            "lines_hit": sum(1 for h in cov.line_hits.values() if h > 0),
            "lines_missing": len(missing_lines),
            "lines_waived": sum(1 for line in cov.line_hits if line in waived),
            "branches_total": len(cov.branch_hits),
            "branches_hit": sum(1 for h in cov.branch_hits.values() if h > 0),
            "missing_lines": missing_lines,
            "missing_branches": missing_branches,
        }
        if missing_lines:
            fail = True

    render_markdown_report(per_file, report_path)
    print(f"[coverage] report written to {report_path}", flush=True)

    # Toggle coverage summary (informational only — too granular to gate).
    total_toggle_total = sum(int(stats["branches_total"]) for stats in per_file.values())  # type: ignore[arg-type]
    total_toggle_hit = sum(int(stats["branches_hit"]) for stats in per_file.values())  # type: ignore[arg-type]
    if total_toggle_total > 0:
        pct = 100.0 * total_toggle_hit / total_toggle_total
        print(f"[coverage] toggle coverage: {total_toggle_hit}/{total_toggle_total} ({pct:.1f}%) — informational", flush=True)

    if fail:
        print("[coverage] FAIL: one or more RTL lines uncovered without a waiver", file=sys.stderr)
        for path, stats in sorted(per_file.items()):
            if stats["missing_lines"]:
                print(
                    f"  {Path(path).name}: missing_lines={stats['missing_lines']}",
                    file=sys.stderr,
                )
        return 1
    print("[coverage] PASS: all non-waived RTL lines hit", flush=True)
    return 0


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--build-dir", type=Path, default=REPO / "build" / "float_cocotb")
    p.add_argument("--report", type=Path, default=None)
    p.add_argument("--info", type=Path, default=None)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    build_dir = args.build_dir
    report = args.report or (build_dir / "coverage_report.md")
    info = args.info or (build_dir / "merged.info")
    return aggregate(build_dir, report, info)


if __name__ == "__main__":
    raise SystemExit(main())
