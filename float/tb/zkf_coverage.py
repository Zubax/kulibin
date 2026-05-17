#!/usr/bin/env python3
"""Merge Verilator coverage, generate an HTML report, and optionally gate uncovered ZKF RTL lines."""

from __future__ import annotations

import argparse
from collections import defaultdict
from html import escape
from pathlib import Path
import shutil
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "float" / "hdl"


def is_zkf_source(path_text: str) -> bool:
    path = Path(path_text)
    return path.parent.name == "hdl" and path.name.endswith(".v") and path.name.startswith(("zkf_", "_zkf_"))


def normalized_source(path_text: str) -> str:
    path = Path(path_text)
    if path.parent.name == "hdl":
        source = RTL_DIR / path.name
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


def uncovered_lines(info_path: Path) -> dict[str, list[int]]:
    missing: dict[str, list[int]] = defaultdict(list)
    current: str | None = None
    with info_path.open() as fp:
        for raw in fp:
            line = raw.strip()
            if line.startswith("SF:"):
                source = line[3:]
                current = source if is_zkf_source(source) else None
            elif current and line.startswith("DA:"):
                lineno_text, hits_text = line[3:].split(",", 1)
                if int(hits_text) == 0:
                    missing[Path(current).name].append(int(lineno_text))
            elif line == "end_of_record":
                current = None
    return {name: sorted(lines) for name, lines in sorted(missing.items())}


def run_genhtml(info_path: Path, output_dir: Path) -> bool:
    tool = shutil.which("genhtml")
    if tool is None:
        return False
    subprocess.run(
        [
            tool,
            "--legend",
            "--show-details",
            "--title",
            "Kulibin Float Verilator Line Coverage",
            "--output-directory",
            str(output_dir),
            str(info_path),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return True


def fallback_html(output_dir: Path, missing: dict[str, list[int]]) -> None:
    rows = []
    if missing:
        for name, lines in missing.items():
            rendered = ", ".join(str(line) for line in lines)
            rows.append(f"<tr><td>{escape(name)}</td><td class='bad'>{escape(rendered)}</td></tr>")
    else:
        rows.append("<tr><td>All ZKF RTL files</td><td class='good'>No uncovered executable lines</td></tr>")

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "index.html").write_text(
        """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Kulibin Float Coverage</title>
<style>
body { margin: 0; font-family: system-ui, sans-serif; background: #111827; color: #f9fafb; }
main { max-width: 960px; margin: 0 auto; padding: 48px 24px; }
h1 { margin: 0 0 24px; font-size: 32px; }
table { width: 100%; border-collapse: collapse; overflow: hidden; border-radius: 8px; }
th, td { padding: 14px 16px; border-bottom: 1px solid #374151; text-align: left; }
th { background: #1f2937; color: #93c5fd; }
td { background: #111827; }
.good { color: #86efac; font-weight: 700; }
.bad { color: #fca5a5; font-weight: 700; }
</style>
</head>
<body><main>
<h1>Kulibin Float Verilator Line Coverage</h1>
<table><thead><tr><th>Source</th><th>Uncovered Lines</th></tr></thead><tbody>
"""
        + "\n".join(rows)
        + """
</tbody></table>
</main></body></html>
""",
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=Path("build/float/verilator"))
    parser.add_argument("--output-dir", type=Path, default=Path("build/float/coverage"))
    parser.add_argument("--gate", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        info_path = merge_coverage(args.build_dir, args.output_dir)
        missing = uncovered_lines(info_path)
        if not run_genhtml(info_path, args.output_dir):
            fallback_html(args.output_dir, missing)
    except Exception as ex:
        print(f"[float-coverage] failed: {ex}", file=sys.stderr)
        return 2

    if missing:
        print("[float-coverage] uncovered ZKF RTL lines:", file=sys.stderr)
        for name, lines in missing.items():
            print(f"  {name}: {lines}", file=sys.stderr)
        return 1 if args.gate else 0

    print(f"[float-coverage] PASS: report written to {args.output_dir / 'index.html'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
