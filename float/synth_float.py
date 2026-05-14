#!/usr/bin/env python3
"""Run out-of-context ECP5 synthesis evaluations for float modules."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from html import escape
import json
import os
from pathlib import Path
import re
import subprocess


REPO = Path(__file__).resolve().parents[1]
BUILD = REPO / "build" / "float_synth"
DEVICE_SPEED_GRADE = "6"
TARGET_FREQ_MHZ = 100

IMPORTANT_UTILIZATION_RESOURCES = (
    "TRELLIS_COMB",
    "TRELLIS_FF",
    "TRELLIS_IO",
    "MULT18X18D",
    "ALU54B",
    "DP16KD",
    "TRELLIS_RAMW",
    "DCCA",
)


@dataclass(frozen=True)
class ModuleSpec:
    name: str
    label: str
    top: str
    kind: str
    wexp: int
    wman: int
    wmag: int
    wscale: int


MODULES = [
    ModuleSpec(
        name="_zkf_pack",
        label="_zkf_pack (external mag_zero/mag_flog2)",
        top="_zkf_pack_synth_top",
        kind="pack",
        wexp=6,
        wman=18,
        wmag=36,
        wscale=8,
    ),
    ModuleSpec(
        name="zkf_mul",
        label="zkf_mul",
        top="zkf_mul_synth_top",
        kind="mul",
        wexp=6,
        wman=18,
        wmag=0,
        wscale=0,
    ),
    ModuleSpec(
        name="_zkf_div_core",
        label="_zkf_div_core",
        top="_zkf_div_core_synth_top",
        kind="div_core",
        wexp=6,
        wman=18,
        wmag=0,
        wscale=0,
    ),
    ModuleSpec(
        name="zkf_div",
        label="zkf_div",
        top="zkf_div_synth_top",
        kind="div",
        wexp=6,
        wman=18,
        wmag=0,
        wscale=0,
    ),
]


def run(command: list[str], log_path: Path) -> None:
    with log_path.open("w") as log:
        log.write("$ " + " ".join(command) + "\n\n")
        log.flush()
        subprocess.run(command, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, check=True)


def write_pack_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    wlog = 1 if spec.wmag <= 2 else (spec.wmag - 1).bit_length()
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     in_valid,
    input  wire                     sign,
    input  wire [{spec.wmag - 1}:0] mag,
    input  wire                     mag_zero,
    input  wire [{wlog - 1}:0]      mag_flog2,
    input  wire signed [{spec.wscale - 1}:0] scale,
    output wire                     out_valid,
    output wire [{wfull - 1}:0]     y
);
    _zkf_pack #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman}),
        .WMAG({spec.wmag}),
        .WSCALE({spec.wscale}),
        .WLOG({wlog})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .sign(sign),
        .mag(mag),
        .mag_zero(mag_zero),
        .mag_flog2(mag_flog2),
        .scale(scale),
        .out_valid(out_valid),
        .y(y)
    );
endmodule

`default_nettype wire
"""
    )


def write_mul_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire [{wfull - 1}:0] a,
    input  wire [{wfull - 1}:0] b,
    output wire                 out_valid,
    output wire [{wfull - 1}:0] y
);
    zkf_mul #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .a(a),
        .b(b),
        .out_valid(out_valid),
        .y(y)
    );
endmodule

`default_nettype wire
"""
    )


def div_params(spec: ModuleSpec) -> tuple[int, int, int]:
    qfrac_base = spec.wman + 4
    qfrac = qfrac_base + (qfrac_base % 2)
    qmag = qfrac + 2
    wqfrac_bits = (qfrac + 1).bit_length()
    wscale = max(spec.wexp, wqfrac_bits) + 2
    return qmag, wscale, (qmag - 1).bit_length()


def latency_cycles(spec: ModuleSpec) -> int:
    if spec.kind == "pack":
        return 2
    if spec.kind == "mul":
        return 4
    if spec.kind == "div_core":
        return spec.wman + 5 + ((spec.wman + 4) % 2)
    if spec.kind == "div":
        return spec.wman + 8 + ((spec.wman + 4) % 2)
    raise ValueError(f"unsupported module kind: {spec.kind}")


def format_latency(cycles: int) -> str:
    suffix = "cycle" if cycles == 1 else "cycles"
    return f"{cycles} {suffix}"


def write_div_core_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    qmag, wscale, qlog = div_params(spec)
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     in_valid,
    input  wire [{wfull - 1}:0]     a,
    input  wire [{wfull - 1}:0]     b,
    output wire                     out_valid,
    output wire                     sign,
    output wire [{qmag - 1}:0]      mag,
    output wire                     mag_zero,
    output wire [{qlog - 1}:0]      mag_flog2,
    output wire signed [{wscale - 1}:0] scale,
    output wire                     div0,
    output wire [{spec.wman - 1}:0] partial_rem
);
    reg                 s1_valid;
    reg [{wfull - 1}:0] s1_a;
    reg [{wfull - 1}:0] s1_b;

    _zkf_div_core #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(s1_valid),
        .a(s1_a),
        .b(s1_b),
        .out_valid(out_valid),
        .sign(sign),
        .mag(mag),
        .mag_zero(mag_zero),
        .mag_flog2(mag_flog2),
        .scale(scale),
        .div0(div0),
        .partial_rem(partial_rem)
    );

    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= in_valid;
        end

        s1_a <= a;
        s1_b <= b;
    end
endmodule

`default_nettype wire
"""
    )


def write_div_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire [{wfull - 1}:0] a,
    input  wire [{wfull - 1}:0] b,
    output wire                 out_valid,
    output wire [{wfull - 1}:0] q,
    output wire                 div0
);
    zkf_div #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .a(a),
        .b(b),
        .out_valid(out_valid),
        .q(q),
        .div0(div0)
    );
endmodule

`default_nettype wire
"""
    )


def write_wrapper(spec: ModuleSpec, path: Path) -> None:
    if spec.kind == "pack":
        write_pack_wrapper(spec, path)
    elif spec.kind == "mul":
        write_mul_wrapper(spec, path)
    elif spec.kind == "div_core":
        write_div_core_wrapper(spec, path)
    elif spec.kind == "div":
        write_div_wrapper(spec, path)
    else:
        raise ValueError(f"unsupported module kind: {spec.kind}")


def write_yosys_script(spec: ModuleSpec, wrapper: Path, netlist: Path, script: Path) -> None:
    if spec.kind == "pack":
        rtl = [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            wrapper,
        ]
    elif spec.kind == "mul":
        rtl = [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            REPO / "float" / "hdl" / "zkf_mul.v",
            wrapper,
        ]
    elif spec.kind == "div_core":
        rtl = [
            REPO / "float" / "hdl" / "_zkf_div_core.v",
            wrapper,
        ]
    elif spec.kind == "div":
        rtl = [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            REPO / "float" / "hdl" / "_zkf_div_core.v",
            REPO / "float" / "hdl" / "zkf_div.v",
            wrapper,
        ]
    else:
        raise ValueError(f"unsupported module kind: {spec.kind}")

    script.write_text(
        "\n".join(
            [f"read_verilog {path}" for path in rtl]
            + [
                f"hierarchy -check -top {spec.top}",
                "proc",
                "opt",
                f"synth_ecp5 -top {spec.top} -noabc9 -retime -abc2 -dff -json {netlist}",
                "stat",
                "",
            ]
        )
    )


def parse_cell_counts(yosys_log: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in yosys_log.splitlines():
        match = re.match(r"\s+([A-Za-z0-9_.$]+)\s+([0-9]+)\s*$", line)
        if match:
            counts[match.group(1)] = int(match.group(2))
        match = re.match(r"\s+([0-9]+)\s+([A-Za-z0-9_.$]+)\s*$", line)
        if match:
            counts[match.group(2)] = int(match.group(1))
    return counts


def read_yosys_cell_counts(netlist: Path, top: str) -> dict[str, int]:
    try:
        data = json.loads(netlist.read_text())
    except json.JSONDecodeError:
        return {}
    modules = data.get("modules")
    if not isinstance(modules, dict):
        return {}
    module = modules.get(top)
    if not isinstance(module, dict):
        return {}
    cells = module.get("cells")
    if not isinstance(cells, dict):
        return {}
    counts: Counter[str] = Counter()
    for cell in cells.values():
        if isinstance(cell, dict) and isinstance(cell.get("type"), str):
            counts[cell["type"]] += 1
    return dict(counts)


def read_nextpnr_report(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def parse_fmax(nextpnr_log: str, report: dict[str, object]) -> str:
    fmax = report.get("fmax")
    if isinstance(fmax, dict) and fmax:
        achieved = []
        for clock in fmax.values():
            if isinstance(clock, dict) and isinstance(clock.get("achieved"), (int, float)):
                achieved.append(float(clock["achieved"]))
        if achieved:
            return f"{max(achieved):.2f} MHz"

    matches = re.findall(r"Max frequency[^:]*:\s*([0-9.]+)\s*MHz", nextpnr_log)
    if matches:
        return f"{max(float(item) for item in matches):.2f} MHz"
    return "not reported"


def timing_met(report: dict[str, object]) -> bool:
    fmax = report.get("fmax")
    if not isinstance(fmax, dict) or not fmax:
        return False
    for clock in fmax.values():
        if not isinstance(clock, dict):
            return False
        achieved = clock.get("achieved")
        constraint = clock.get("constraint")
        if not isinstance(achieved, (int, float)) or not isinstance(constraint, (int, float)):
            return False
        if float(achieved) < float(constraint):
            return False
    return True


def parse_slack(nextpnr_log: str, report: dict[str, object]) -> str:
    fmax = report.get("fmax")
    if isinstance(fmax, dict) and fmax:
        lines = []
        for clock_name, clock in fmax.items():
            if not isinstance(clock, dict):
                continue
            achieved = clock.get("achieved")
            constraint = clock.get("constraint")
            if isinstance(achieved, (int, float)) and isinstance(constraint, (int, float)) and achieved > 0:
                slack_ns = (1000.0 / float(constraint)) - (1000.0 / float(achieved))
                lines.append(
                    f"{clock_name}: {slack_ns:.3f} ns at {float(constraint):.2f} MHz target "
                    f"(achieved {float(achieved):.2f} MHz)"
                )
        if lines:
            return "\n".join(lines)

    slack_lines = [line.strip() for line in nextpnr_log.splitlines() if "slack" in line.lower()]
    return "\n".join(slack_lines[-8:]) if slack_lines else "not reported"


def endpoint_name(endpoint: object) -> str:
    if isinstance(endpoint, dict):
        cell = endpoint.get("cell", "?")
        port = endpoint.get("port", "?")
        loc = endpoint.get("loc")
        loc_text = f" @{loc[0]},{loc[1]}" if isinstance(loc, list) and len(loc) >= 2 else ""
        return f"{cell}.{port}{loc_text}"
    return str(endpoint)


def path_delay_ns(path: dict[str, object]) -> float:
    segments = path.get("path")
    if not isinstance(segments, list):
        return 0.0
    return sum(float(seg.get("delay", 0.0)) for seg in segments if isinstance(seg, dict))


def path_constraint_ns(path: dict[str, object], report: dict[str, object]) -> float | None:
    path_from = str(path.get("from", ""))
    path_to = str(path.get("to", ""))
    if "<async>" in path_from or "<async>" in path_to:
        return None

    fmax = report.get("fmax")
    if not isinstance(fmax, dict):
        return None
    for clock_name, clock in fmax.items():
        if str(clock_name) not in path_to or not isinstance(clock, dict):
            continue
        constraint = clock.get("constraint")
        if isinstance(constraint, (int, float)) and constraint > 0:
            return 1000.0 / float(constraint)
    return None


def path_slack_ns(path: dict[str, object], report: dict[str, object]) -> float | None:
    constraint = path_constraint_ns(path, report)
    if constraint is None:
        return None
    return constraint - path_delay_ns(path)


def format_slack(path: dict[str, object], report: dict[str, object]) -> str:
    slack = path_slack_ns(path, report)
    return f"{slack:.3f} ns" if slack is not None else "n/a"


def path_endpoints(path: dict[str, object]) -> tuple[str, str]:
    segments = path.get("path")
    if isinstance(segments, list) and segments:
        first = segments[0]
        last = segments[-1]
        if isinstance(first, dict) and isinstance(last, dict):
            return endpoint_name(first.get("from")), endpoint_name(last.get("to"))
    return str(path.get("from", "?")), str(path.get("to", "?"))


def format_timing_path(path: dict[str, object]) -> str:
    segments = path.get("path")
    if not isinstance(segments, list) or not segments:
        return "not reported"

    lines = [
        f"{path.get('from', '?')} -> {path.get('to', '?')}",
        f"total delay: {path_delay_ns(path):.3f} ns",
    ]
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        lines.append(
            f"{seg.get('type', '?'):>10} {float(seg.get('delay', 0.0)):.3f} ns  "
            f"{endpoint_name(seg.get('from'))} -> {endpoint_name(seg.get('to'))}"
        )
        net = seg.get("net")
        if isinstance(net, str) and net:
            lines.append(f"{'net':>10} {net}")
        sources = seg.get("sources")
        if isinstance(sources, list):
            for source in sources:
                lines.append(f"{'source':>10} {source}")
    return "\n".join(lines)


def critical_paths(report: dict[str, object]) -> list[dict[str, object]]:
    paths = report.get("critical_paths")
    if not isinstance(paths, list):
        return []
    return [path for path in paths if isinstance(path, dict)]


def critical_path_histogram(report: dict[str, object]) -> str:
    paths = critical_paths(report)
    if not paths:
        return "not reported"

    delays = [path_delay_ns(path) for path in paths]
    lo = min(delays)
    hi = max(delays)
    if hi <= lo:
        return f"{lo:.3f} ns | {'#' * len(delays)} ({len(delays)})"

    bin_count = min(10, max(1, len(delays)))
    step = (hi - lo) / bin_count
    counts = [0 for _ in range(bin_count)]
    for delay in delays:
        index = min(bin_count - 1, int((delay - lo) / step))
        counts[index] += 1

    lines = []
    for index, count in enumerate(counts):
        start = lo + index * step
        end = hi if index == bin_count - 1 else start + step
        lines.append(f"{start:7.3f}..{end:7.3f} ns | {'#' * count} ({count})")
    return "\n".join(lines)


def parse_timing_path(nextpnr_log: str, report: dict[str, object]) -> str:
    paths = critical_paths(report)
    if paths:
        return format_timing_path(paths[0])

    lines = nextpnr_log.splitlines()
    for index, line in enumerate(lines):
        if "critical path" in line.lower():
            end = len(lines)
            for stop in range(index + 1, len(lines)):
                if lines[stop].startswith("Warning: Max frequency") or lines[stop].startswith("Info: Max delay"):
                    end = stop
                    break
            return "\n".join(lines[index:end]).rstrip()
    timing_lines = [line for line in lines if "Max frequency" in line or "Info: curr total" in line]
    return "\n".join(timing_lines[-12:]) if timing_lines else "not reported"


def critical_path_overview_html(report: dict[str, object], _anchor_prefix: str) -> str:
    rows = []
    paths = sorted(critical_paths(report), key=path_delay_ns, reverse=True)

    for index, path in enumerate(paths[:10], start=1):
        startpoint, endpoint = path_endpoints(path)
        slack = path_slack_ns(path, report)
        slack_class = "unknown" if slack is None else ("pass" if slack >= 0.0 else "fail")
        rows.append(
            "<tr>"
            f"<td>{index}</td>"
            f"<td>{escape(str(path.get('from', '?')))} -> {escape(str(path.get('to', '?')))}</td>"
            f"<td>{path_delay_ns(path):.3f} ns</td>"
            f"<td><span class=\"slack {slack_class}\">{escape(format_slack(path, report))}</span></td>"
            f"<td>{escape(startpoint)}</td>"
            f"<td>{escape(endpoint)}</td>"
            "</tr>"
        )

    if not rows:
        return "<p>No critical paths were reported.</p>"

    return (
        "<table class=\"paths\">"
        "<thead><tr><th>#</th><th>Domain</th><th>Delay</th><th>Slack</th><th>Startpoint</th>"
        "<th>Endpoint</th></tr></thead>"
        "<tbody>"
        + "\n".join(rows)
        + "</tbody></table>"
    )


def format_used_available(used: int, available: int | None = None) -> str:
    if available is not None and available > 0:
        return f"{used}/{available} ({100.0 * used / available:.2f}%)"
    return str(used)


def nextpnr_resource(report: dict[str, object], key: str) -> tuple[int, int | None] | None:
    utilization = report.get("utilization")
    if isinstance(utilization, dict):
        item = utilization.get(key)
        if isinstance(item, dict):
            used = item.get("used")
            available = item.get("available")
            if isinstance(used, int):
                return used, available if isinstance(available, int) else None
    return None


def format_nextpnr_resource(report: dict[str, object], key: str, fallback_used: int | None = None) -> str:
    resource = nextpnr_resource(report, key)
    if resource is not None:
        return format_used_available(resource[0], resource[1])
    if fallback_used is not None:
        return str(fallback_used)
    return "not reported"


def parse_nextpnr_total_lut4(nextpnr_log: str) -> tuple[int, int | None] | None:
    match = re.search(r"Total LUT4s:\s*([0-9]+)/([0-9]+)", nextpnr_log)
    if match:
        return int(match.group(1)), int(match.group(2))
    return None


def format_nextpnr_total_lut4(nextpnr_log: str) -> str:
    resource = parse_nextpnr_total_lut4(nextpnr_log)
    if resource is None:
        return "not reported"
    return format_used_available(resource[0], resource[1])


def format_yosys_cell_counts(cells: dict[str, int]) -> str:
    keys = [
        "LUT4",
        "TRELLIS_FF",
        "CCU2C",
        "PFUMX",
        "L6MUX21",
        "MULT18X18D",
        "ALU54B",
        "DP16KD",
    ]
    extra_keys = (
        key
        for key, value in cells.items()
        if value and key not in keys and not key.startswith("$")
    )
    keys.extend(sorted(extra_keys))
    lines = [f"{key}: {cells[key]}" for key in keys if cells.get(key, 0)]
    return "\n".join(lines) if lines else "not reported"


def parse_nextpnr_utilization(nextpnr_log: str, report: dict[str, object]) -> str:
    lines = []
    total_lut4 = parse_nextpnr_total_lut4(nextpnr_log)
    if total_lut4 is not None:
        lines.append(f"Total LUT4s: {format_used_available(total_lut4[0], total_lut4[1])}")

    utilization = report.get("utilization")
    if isinstance(utilization, dict):
        keys = set(IMPORTANT_UTILIZATION_RESOURCES)
        keys.update(
            key
            for key, item in utilization.items()
            if isinstance(key, str)
            and isinstance(item, dict)
            and isinstance(item.get("used"), int)
            and item["used"] > 0
        )
        for key in sorted(keys):
            resource = nextpnr_resource(report, key)
            if resource is not None:
                lines.append(f"{key}: {format_used_available(resource[0], resource[1])}")
        if lines:
            return "\n".join(lines)

    useful = []
    for line in nextpnr_log.splitlines():
        if any(
            cell in line
            for cell in ("TRELLIS_SLICE", "TRELLIS_FF", "LUT4", "PFU", "MULT18X18D", "DP16KD")
        ):
            useful.append(line.strip())
    return "\n".join(useful[-12:]) if useful else "not reported"


def summarize_report_json(report: dict[str, object], path: Path) -> str:
    if not report:
        return "nextpnr did not emit a JSON report"
    keys = ", ".join(sorted(report.keys()))
    return f"nextpnr JSON report keys: {keys}"


def synthesize(spec: ModuleSpec) -> dict[str, str]:
    module_dir = BUILD / spec.name
    module_dir.mkdir(parents=True, exist_ok=True)

    wrapper = module_dir / f"{spec.name}_wrapper.v"
    yosys_script = module_dir / f"{spec.name}.ys"
    netlist = module_dir / f"{spec.name}.json"
    textcfg = module_dir / f"{spec.name}.config"
    nextpnr_report = module_dir / f"{spec.name}_nextpnr.json"
    yosys_log = module_dir / "yosys.log"
    nextpnr_log = module_dir / "nextpnr.log"

    write_wrapper(spec, wrapper)
    write_yosys_script(spec, wrapper, netlist, yosys_script)

    yosys = os.environ.get("YOSYS", "yosys")
    nextpnr = os.environ.get("NEXTPNR_ECP5", "nextpnr-ecp5")

    run([yosys, "-s", str(yosys_script)], yosys_log)
    run(
        [
            nextpnr,
            "--85k",
            "--package",
            "CABGA381",
            "--speed",
            DEVICE_SPEED_GRADE,
            "--freq",
            str(TARGET_FREQ_MHZ),
            "--timing-allow-fail",
            "--lpf-allow-unconstrained",
            "--json",
            str(netlist),
            "--textcfg",
            str(textcfg),
            "--report",
            str(nextpnr_report),
        ],
        nextpnr_log,
    )

    yosys_text = yosys_log.read_text()
    nextpnr_text = nextpnr_log.read_text()
    report_data = read_nextpnr_report(nextpnr_report)
    cells = read_yosys_cell_counts(netlist, spec.top) or parse_cell_counts(yosys_text)
    utilization = report_data.get("utilization")
    nextpnr_ff = None
    if isinstance(utilization, dict):
        ff_util = utilization.get("TRELLIS_FF")
        if isinstance(ff_util, dict) and isinstance(ff_util.get("used"), int):
            nextpnr_ff = ff_util["used"]
    if spec.kind == "pack":
        params = f"WEXP={spec.wexp}, WMAN={spec.wman}, WMAG={spec.wmag}, WSCALE={spec.wscale}, log2=external"
    elif spec.kind in {"div_core", "div"}:
        qmag, wscale, _qlog = div_params(spec)
        params = f"WEXP={spec.wexp}, WMAN={spec.wman}, QWMAG={qmag}, WSCALE={wscale}"
    else:
        params = f"WEXP={spec.wexp}, WMAN={spec.wman}"

    return {
        "name": spec.name,
        "label": spec.label,
        "params": params,
        "latency": format_latency(latency_cycles(spec)),
        "fmax": parse_fmax(nextpnr_text, report_data),
        "target": f"{TARGET_FREQ_MHZ} MHz",
        "status": "PASS" if timing_met(report_data) else "FAIL",
        "lut": str(cells.get("LUT4", cells.get("$_LUT_", "not reported"))),
        "lut_placed": format_nextpnr_total_lut4(nextpnr_text),
        "ff": str(cells.get("TRELLIS_FF", nextpnr_ff if nextpnr_ff is not None else "not reported")),
        "comb": format_nextpnr_resource(report_data, "TRELLIS_COMB"),
        "carry": str(cells.get("CCU2C", 0)),
        "pfumx": str(cells.get("PFUMX", 0)),
        "l6mux21": str(cells.get("L6MUX21", 0)),
        "dsp": format_nextpnr_resource(report_data, "MULT18X18D", cells.get("MULT18X18D", 0)),
        "alu54": format_nextpnr_resource(report_data, "ALU54B", cells.get("ALU54B", 0)),
        "bram": format_nextpnr_resource(report_data, "DP16KD", cells.get("DP16KD", 0)),
        "io": format_nextpnr_resource(report_data, "TRELLIS_IO"),
        "yosys_cells": format_yosys_cell_counts(cells),
        "utilization": parse_nextpnr_utilization(nextpnr_text, report_data),
        "slack": parse_slack(nextpnr_text, report_data),
        "path_overview": critical_path_overview_html(report_data, spec.name.replace("_", "-")),
        "json": summarize_report_json(report_data, nextpnr_report),
        "dir": str(module_dir.relative_to(REPO)),
        "artifact_dir": str(module_dir.relative_to(BUILD)),
        "yosys_log": str((module_dir / "yosys.log").relative_to(BUILD)),
        "nextpnr_log": str((module_dir / "nextpnr.log").relative_to(BUILD)),
        "nextpnr_json": str(nextpnr_report.relative_to(BUILD)),
    }


def write_html(results: list[dict[str, str]]) -> None:
    rows = []
    details = []
    for result in results:
        status_class = "pass" if result["status"] == "PASS" else "fail"
        rows.append(
            "<tr>"
            f"<td>{escape(result['label'])}</td>"
            f"<td>{escape(result['params'])}</td>"
            f"<td>{escape(result['latency'])}</td>"
            f"<td>{escape(result['target'])}</td>"
            f"<td>{escape(result['fmax'])}</td>"
            f"<td><span class=\"status {status_class}\">{escape(result['status'])}</span></td>"
            f"<td class=\"resource\">{escape(result['lut'])}</td>"
            f"<td class=\"resource\">{escape(result['lut_placed'])}</td>"
            f"<td class=\"resource\">{escape(result['ff'])}</td>"
            f"<td class=\"resource\">{escape(result['comb'])}</td>"
            f"<td class=\"resource\">{escape(result['carry'])}</td>"
            f"<td class=\"resource\">{escape(result['pfumx'])}</td>"
            f"<td class=\"resource\">{escape(result['l6mux21'])}</td>"
            f"<td class=\"resource\">{escape(result['dsp'])}</td>"
            f"<td class=\"resource\">{escape(result['alu54'])}</td>"
            f"<td class=\"resource\">{escape(result['bram'])}</td>"
            f"<td class=\"resource\">{escape(result['io'])}</td>"
            "<td>"
            f"<a href=\"{escape(result['nextpnr_log'])}\">nextpnr</a> | "
            f"<a href=\"{escape(result['yosys_log'])}\">Yosys</a> | "
            f"<a href=\"{escape(result['nextpnr_json'])}\">JSON</a>"
            "</td>"
            "</tr>"
        )
        details.append(
            f"<h2>{escape(result['label'])}</h2>"
            "<h3>Artifacts</h3>"
            "<p>"
            f"<a href=\"{escape(result['nextpnr_log'])}\">nextpnr log</a> | "
            f"<a href=\"{escape(result['yosys_log'])}\">Yosys log</a> | "
            f"<a href=\"{escape(result['nextpnr_json'])}\">nextpnr JSON</a>"
            "</p>"
            "<h3>Worst Slack</h3>"
            f"<pre>{escape(result['slack'])}</pre>"
            "<h3>Worst Critical Paths</h3>"
            f"{result['path_overview']}"
            "<h3>Utilization</h3>"
            f"<pre>{escape(result['utilization'])}</pre>"
            "<h3>Yosys Cell Counts</h3>"
            f"<pre>{escape(result['yosys_cells'])}</pre>"
            "<h3>Report JSON</h3>"
            f"<pre>{escape(result['json'])}</pre>"
        )

    (BUILD / "index.html").write_text(
        """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Kulibin Float Synthesis Report</title>
<style>
body { font-family: sans-serif; margin: 2rem; color: #111; }
table { border-collapse: collapse; margin-bottom: 2rem; }
th, td { border: 1px solid #bbb; padding: 0.35rem 0.6rem; text-align: left; }
th { background: #eee; }
td.resource { white-space: nowrap; }
.status { border-radius: 999px; display: inline-block; font-weight: 700; padding: 0.2rem 0.6rem; }
.status.pass { background: #11823b; color: #fff; }
.status.fail { background: #c82424; color: #fff; }
.slack { border-radius: 999px; display: inline-block; font-weight: 700; padding: 0.12rem 0.45rem; }
.slack.pass { background: #d8f2df; color: #0d5e2c; }
.slack.fail { background: #ffe0df; color: #9e1a1a; }
.slack.unknown { background: #e8e8e8; color: #555; }
.paths td:nth-child(5), .paths td:nth-child(6) { max-width: 28rem; overflow-wrap: anywhere; }
pre { background: #f6f6f6; border: 1px solid #ddd; padding: 0.8rem; overflow-x: auto; }
</style>
</head>
<body>
<h1>Kulibin Float Synthesis Report</h1>
<p>Flow: Yosys synth_ecp5 with -noabc9 -retime -abc2 -dff, nextpnr-ecp5 for LFE5U-85F CABGA381 speed grade 6 at 100 MHz.</p>
<p>Helper-module rows are standalone out-of-context builds with unconstrained wrapper inputs. Parent-module rows are
flattened and context-optimized, so helper and parent resource counts are not additive.</p>
<p>The _zkf_pack helper row provides mag_zero and mag_flog2 as wrapper inputs; it does not include
_zkf_ilog2_floor. A row that instantiates _zkf_ilog2_floor must be named as such.</p>
<p>Yosys cell columns are post-synthesis primitive counts; placed utilization columns and hard-block capacities come
from nextpnr.</p>
<table>
<thead><tr>
<th>Module</th><th>Parameters</th><th>Latency</th><th>Target</th><th>Fmax</th><th>Status</th>
<th>Yosys LUT4</th><th>Placed LUT4</th><th>FF</th><th>TRELLIS_COMB</th>
<th>CCU2C</th><th>PFUMX</th><th>L6MUX21</th><th>DSP MULT18X18D</th>
<th>ALU54B</th><th>BRAM DP16KD</th><th>IO</th><th>Logs</th>
</tr></thead>
<tbody>
"""
        + "\n".join(rows)
        + """
</tbody>
</table>
"""
        + "\n".join(details)
        + """
</body>
</html>
"""
    )


def main() -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    results = [synthesize(spec) for spec in MODULES]
    write_html(results)
    print(f"wrote {BUILD / 'index.html'}")


if __name__ == "__main__":
    main()
