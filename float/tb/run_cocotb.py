#!/usr/bin/env python3
"""Run the ZKF Cocotb test suites without pre-generated vector files."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import secrets
import sys
import xml.etree.ElementTree as ET

from cocotb_tools.runner import get_runner


REPO = Path(__file__).resolve().parents[2]
FLOAT = Path(__file__).resolve().parents[1]
TB = Path(__file__).resolve().parent
RTL = FLOAT / "hdl"

RTL_ILOG2 = [RTL / "_zkf_ilog2_floor.v"]
RTL_PACK = [RTL / "_zkf_pack.v"]
RTL_MUL = [RTL / "_zkf_pack.v", RTL / "zkf_mul.v"]
RTL_ADDSUB = [RTL / "_zkf_ilog2_floor.v", RTL / "_zkf_pack.v", RTL / "zkf_addsub.v"]
RTL_DIV = [RTL / "_zkf_pack.v", RTL / "_zkf_div_core.v", RTL / "zkf_div.v"]

SIMS = ("icarus", "verilator")
SUITES = ("ilog2", "pack", "mul", "addsub", "div")
SKIP_REASON = {
    ("verilator", "ilog2"): "Verilator mis-elaborates the recursive _zkf_ilog2_floor implementation",
}


@dataclass(frozen=True)
class RunConfig:
    suite: str
    name: str
    top: str
    test_module: str
    sources: tuple[Path, ...]
    parameters: dict[str, int]
    env: dict[str, str]


def ilog2_configs() -> list[RunConfig]:
    configs = []
    for width, count in ((1, 0), (2, 0), (3, 0), (4, 0), (7, 0), (12, 0), (17, 512), (32, 512), (64, 512)):
        windex = 1 if width <= 2 else (width - 1).bit_length()
        configs.append(
            RunConfig(
                suite="ilog2",
                name=f"w{width}",
                top="_zkf_ilog2_floor",
                test_module="test_ilog2",
                sources=tuple(RTL_ILOG2),
                parameters={"W": width, "WINDEX": windex},
                env={"ZKF_WIDTH": str(width), "ZKF_RANDOM_COUNT": str(count)},
            )
        )
    return configs


def pack_configs() -> list[RunConfig]:
    specs = (
        ("w2_m4_exhaustive", 2, 4, 4, "exhaustive", 0),
        ("w3_m4_exhaustive", 3, 4, 5, "exhaustive", 0),
        ("w5_m8_manual_random", 5, 8, 8, "random", 768),
        ("w8_m24_random", 8, 24, 12, "random", 2048),
    )
    return [
        RunConfig(
            suite="pack",
            name=name,
            top="_zkf_pack",
            test_module="test_pack",
            sources=tuple(RTL_PACK),
            parameters={"WEXP": wexp, "WMAN": wman, "WEXP_UNBIASED": wunbiased},
            env={
                "ZKF_WEXP": str(wexp),
                "ZKF_WMAN": str(wman),
                "ZKF_WEXP_UNBIASED": str(wunbiased),
                "ZKF_KIND": kind,
                "ZKF_RANDOM_COUNT": str(count),
            },
        )
        for name, wexp, wman, wunbiased, kind, count in specs
    ]


def arithmetic_configs(suite: str) -> list[RunConfig]:
    if suite == "mul":
        top = "zkf_mul"
        test_module = "test_mul"
        sources = tuple(RTL_MUL)
    elif suite == "addsub":
        top = "zkf_addsub"
        test_module = "test_addsub"
        sources = tuple(RTL_ADDSUB)
    elif suite == "div":
        top = "zkf_div"
        test_module = "test_div"
        sources = tuple(RTL_DIV)
    else:
        raise ValueError(suite)

    specs = [
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

    return [
        RunConfig(
            suite=suite,
            name=name,
            top=top,
            test_module=test_module,
            sources=sources,
            parameters={"WEXP": wexp, "WMAN": wman},
            env={
                "ZKF_WEXP": str(wexp),
                "ZKF_WMAN": str(wman),
                "ZKF_KIND": kind,
                "ZKF_RANDOM_COUNT": str(count),
            },
        )
        for name, wexp, wman, kind, count in specs
    ]


def configs_for_suite(suite: str) -> list[RunConfig]:
    if suite == "ilog2":
        return ilog2_configs()
    if suite == "pack":
        return pack_configs()
    if suite in ("mul", "addsub", "div"):
        return arithmetic_configs(suite)
    raise ValueError(suite)


def build_args(sim: str) -> list[str]:
    if sim == "icarus":
        return ["-Wall", "-Wno-timescale"]
    if sim == "verilator":
        return [
            "--timing",
            "-Wno-TIMESCALEMOD",
            "-Wno-WIDTHEXPAND",
            "-Wno-WIDTHTRUNC",
            "-Wno-DECLFILENAME",
            "-Wno-UNOPTFLAT",
        ]
    raise ValueError(sim)


def run_one(sim: str, config: RunConfig, build_root: Path, seed: int) -> None:
    work = build_root / sim / config.suite / config.name
    work.mkdir(parents=True, exist_ok=True)

    env = {
        **config.env,
        "ZKF_SIM": sim,
        "ZKF_CONFIG": config.name,
        "ZKF_SEED": f"0x{seed:016x}",
        "PYTHONPATH": f"{TB}{os.pathsep}{os.environ.get('PYTHONPATH', '')}",
        "PYTEST_ADDOPTS": "",
        "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1",
        "COCOTB_REWRITE_ASSERTION_FILES": "",
    }

    print(
        f"[float-cocotb] sim={sim} suite={config.suite} config={config.name} "
        f"seed=0x{seed:016x}",
        flush=True,
    )
    runner = get_runner(sim)
    runner.build(
        sources=[str(path) for path in config.sources],
        hdl_toplevel=config.top,
        parameters=config.parameters,
        build_args=build_args(sim),
        build_dir=work,
        always=True,
        timescale=("1ns", "1ps"),
    )
    old_pytest_addopts = os.environ.pop("PYTEST_ADDOPTS", None)
    old_pytest_autoload = os.environ.get("PYTEST_DISABLE_PLUGIN_AUTOLOAD")
    old_cocotb_rewrite = os.environ.get("COCOTB_REWRITE_ASSERTION_FILES")
    os.environ["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    os.environ["COCOTB_REWRITE_ASSERTION_FILES"] = ""
    try:
        result_xml = runner.test(
            test_module=config.test_module,
            hdl_toplevel=config.top,
            hdl_toplevel_lang="verilog",
            seed=seed,
            extra_env=env,
            build_dir=work,
            test_dir=TB,
            results_xml=str(work / "results.xml"),
            timescale=("1ns", "1ps"),
        )
        tree = ET.parse(result_xml)
        failures = tree.findall(".//failure") + tree.findall(".//error")
        if failures:
            messages = []
            for failure in failures:
                message = failure.attrib.get("error_msg") or failure.attrib.get("message") or ET.tostring(
                    failure,
                    encoding="unicode",
                )
                messages.append(message)
            raise RuntimeError("; ".join(messages))
    finally:
        if old_pytest_addopts is not None:
            os.environ["PYTEST_ADDOPTS"] = old_pytest_addopts
        if old_pytest_autoload is None:
            os.environ.pop("PYTEST_DISABLE_PLUGIN_AUTOLOAD", None)
        else:
            os.environ["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = old_pytest_autoload
        if old_cocotb_rewrite is None:
            os.environ.pop("COCOTB_REWRITE_ASSERTION_FILES", None)
        else:
            os.environ["COCOTB_REWRITE_ASSERTION_FILES"] = old_cocotb_rewrite


def skip_reason(sim: str, config: RunConfig) -> str | None:
    return SKIP_REASON.get((sim, config.suite))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sim", choices=("all", *SIMS), default="all")
    parser.add_argument("--suite", choices=("all", *SUITES), default="all")
    parser.add_argument("--seed", type=lambda text: int(text, 0), default=None)
    parser.add_argument("--build-dir", type=Path, default=REPO / "build" / "float_cocotb")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    sims = SIMS if args.sim == "all" else (args.sim,)
    suites = SUITES if args.suite == "all" else (args.suite,)
    seed = args.seed if args.seed is not None else secrets.randbits(64)

    print(f"[float-cocotb] base seed=0x{seed:016x}", flush=True)
    run_count = 0
    skip_count = 0
    for sim in sims:
        for suite in suites:
            for config in configs_for_suite(suite):
                reason = skip_reason(sim, config)
                if reason is not None:
                    print(
                        f"[float-cocotb] skip sim={sim} suite={config.suite} config={config.name}: {reason}",
                        flush=True,
                    )
                    skip_count += 1
                    continue
                run_one(sim, config, args.build_dir, seed)
                run_count += 1
    print(f"[float-cocotb] all selected runnable suites passed ({run_count} run, {skip_count} skipped)", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise
    except BaseException as ex:
        print(f"[float-cocotb] failed: {ex}", file=sys.stderr, flush=True)
        raise
