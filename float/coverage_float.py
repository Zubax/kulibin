#!/usr/bin/env python3
"""Run Verilator line coverage for the float packer and multiplier RTL."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import shutil
import subprocess


REPO = Path(__file__).resolve().parents[1]
BUILD = REPO / "build" / "float_coverage"
TARGET_RTL = (
    "float/hdl/_zkf_pack.v",
    "float/hdl/zkf_mul.v",
)


@dataclass(frozen=True)
class CoverageTest:
    name: str
    top: str
    sources: tuple[str, ...]


TESTS = (
    CoverageTest(
        name="pack_min",
        top="_zkf_pack_min_tb",
        sources=(
            "float/hdl/_zkf_ilog2_floor.v",
            "float/hdl/_zkf_pack.v",
            "float/tb/_zkf_pack_tb_wrapper.v",
            "float/tb/_zkf_pack_min_tb.v",
        ),
    ),
    CoverageTest(
        name="mul_min",
        top="zkf_mul_min_tb",
        sources=(
            "float/hdl/_zkf_pack.v",
            "float/hdl/zkf_mul.v",
            "float/tb/zkf_mul_min_tb.v",
        ),
    ),
)


def run(command: list[str], cwd: Path = REPO) -> None:
    print("$ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def build_and_run(test: CoverageTest) -> Path:
    work = BUILD / test.name
    work.mkdir(parents=True, exist_ok=True)

    run(
        [
            "verilator",
            "--binary",
            "--timing",
            "--coverage-line",
            "-Wno-TIMESCALEMOD",
            "-Wno-WIDTHEXPAND",
            "-Wno-WIDTHTRUNC",
            "--top-module",
            test.top,
            "-Mdir",
            str(work.relative_to(REPO)),
            *test.sources,
        ]
    )
    run([str(work / f"V{test.top}")], cwd=work)

    coverage = work / "coverage.dat"
    if not coverage.exists():
        raise RuntimeError(f"{test.name} did not produce {coverage}")
    return coverage


def normalize_source_name(name: str) -> str:
    path = Path(name)
    if path.is_absolute():
        try:
            return path.relative_to(REPO).as_posix()
        except ValueError:
            return path.as_posix()
    return path.as_posix()


def read_line_coverage(info: Path) -> dict[str, dict[int, int]]:
    coverage: dict[str, dict[int, int]] = {}
    current_file = ""

    for line in info.read_text().splitlines():
        if line.startswith("SF:"):
            current_file = normalize_source_name(line[3:])
            coverage.setdefault(current_file, {})
        elif line.startswith("DA:") and current_file:
            line_number_text, count_text, *_ = line[3:].split(",")
            coverage[current_file][int(line_number_text)] = int(count_text)

    return coverage


def write_reports(coverage_files: list[Path]) -> Path:
    merged_dat = BUILD / "coverage.dat"
    merged_info = BUILD / "coverage.info"

    run(["verilator_coverage", "--write", str(merged_dat.relative_to(REPO)), *map(str, coverage_files)])
    run(["verilator_coverage", "--write-info", str(merged_info.relative_to(REPO)), str(merged_dat.relative_to(REPO))])

    if shutil.which("genhtml") is not None:
        html = BUILD / "html"
        run(
            [
                "genhtml",
                "--quiet",
                "--output-directory",
                str(html.relative_to(REPO)),
                str(merged_info.relative_to(REPO)),
            ]
        )
        print(f"wrote {html / 'index.html'}")

    return merged_info


def assert_full_target_coverage(info: Path) -> None:
    coverage = read_line_coverage(info)
    failed = False

    for target in TARGET_RTL:
        lines = coverage.get(target)
        if not lines:
            raise RuntimeError(f"{target} has no coverage data in {info}")

        total = len(lines)
        covered = sum(1 for count in lines.values() if count > 0)
        uncovered = [line_number for line_number, count in sorted(lines.items()) if count == 0]
        percent = 100.0 * covered / total
        print(f"{target}: {covered}/{total} lines covered ({percent:.1f}%)")

        if uncovered:
            failed = True
            print(f"uncovered lines in {target}: {', '.join(str(item) for item in uncovered)}")

    if failed:
        raise SystemExit("float RTL line coverage is below 100%")


def main() -> None:
    if BUILD.exists():
        shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True)

    coverage_files = [build_and_run(test) for test in TESTS]
    merged_info = write_reports(coverage_files)
    assert_full_target_coverage(merged_info)
    print(f"wrote {merged_info}")


if __name__ == "__main__":
    main()
