#!/usr/bin/env python3
"""Run out-of-context synthesis evaluations for float modules."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from html import escape
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess


REPO = Path(__file__).resolve().parents[1]
YOSYS_BUILD = REPO / "build" / "float_synth_yosys"
DIAMOND_BUILD = REPO / "build" / "float_synth_diamond"

DEVICE_SPEED_GRADE = "6"
YOSYS_TARGET_FREQ_MHZ = float(os.environ.get("YOSYS_TARGET_FREQ_MHZ", "100"))
DIAMOND_DEVICE = os.environ.get("DIAMOND_DEVICE", "LFE5U-85F-6BG381C")
DIAMOND_TARGET_FREQ_MHZ = float(os.environ.get("DIAMOND_TARGET_FREQ_MHZ", "100"))
DIAMOND_ROUTE_PASSES = int(os.environ.get("DIAMOND_ROUTE_PASSES", "6"))

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

SYNTH_REG_ATTR = '(* keep = "true", syn_preserve = "true" *)'


@dataclass(frozen=True)
class ModuleSpec:
    name: str
    label: str
    top: str
    kind: str
    wexp: int
    wman: int
    wexp_unbiased: int
    wint: int = 0
    wexp_in: int = 0
    wman_in: int = 0
    wexp_out: int = 0
    wman_out: int = 0


@dataclass(frozen=True)
class DiamondTools:
    diamond: Path
    diamond_env: Path | None


@dataclass(frozen=True)
class DiamondReportPaths:
    twr: Path | None
    lse_twr: Path | None
    mrp: Path | None
    par: Path | None


MODULES = [
    ModuleSpec(
        name="_zkf_pack",
        label="_zkf_pack (normalized GRS)",
        top="_zkf_pack_synth_top",
        kind="pack",
        wexp=6,
        wman=18,
        wexp_unbiased=8,
    ),
    ModuleSpec(
        name="zkf_mul",
        label="zkf_mul",
        top="zkf_mul_synth_top",
        kind="mul",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_add",
        label="zkf_add",
        top="zkf_add_synth_top",
        kind="add",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_addsub",
        label="zkf_addsub",
        top="zkf_addsub_synth_top",
        kind="addsub",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="_zkf_div_core",
        label="_zkf_div_core",
        top="_zkf_div_core_synth_top",
        kind="div_core",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_div",
        label="zkf_div",
        top="zkf_div_synth_top",
        kind="div",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_cmp",
        label="zkf_cmp",
        top="zkf_cmp_synth_top",
        kind="cmp",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_sort",
        label="zkf_sort",
        top="zkf_sort_synth_top",
        kind="sort",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_mul_ilog2_const",
        label="zkf_mul_ilog2_const (K=+10)",
        top="zkf_mul_ilog2_const_synth_top",
        kind="mul_ilog2_const",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
    ),
    ModuleSpec(
        name="zkf_from_int",
        label="zkf_from_int (WINT=32)",
        top="zkf_from_int_synth_top",
        kind="from_int",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wint=32,
    ),
    ModuleSpec(
        name="zkf_to_int",
        label="zkf_to_int (WINT=32)",
        top="zkf_to_int_synth_top",
        kind="to_int",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wint=32,
    ),
    ModuleSpec(
        name="zkf_resize_narrow",
        label="zkf_resize 6/18 -> 5/11 (narrowing)",
        top="zkf_resize_narrow_synth_top",
        kind="resize",
        wexp=6,
        wman=18,
        wexp_unbiased=0,
        wexp_in=6,
        wman_in=18,
        wexp_out=5,
        wman_out=11,
    ),
    ModuleSpec(
        name="zkf_resize_widen",
        label="zkf_resize 5/11 -> 6/18 (widening)",
        top="zkf_resize_widen_synth_top",
        kind="resize",
        wexp=5,
        wman=11,
        wexp_unbiased=0,
        wexp_in=5,
        wman_in=11,
        wexp_out=6,
        wman_out=18,
    ),
]


MUL_ILOG2_CONST_K = 10  # representative midrange shift for the synthesis evaluation harness


def format_mhz(value: float) -> str:
    return f"{value:g} MHz"


def generated_local_time() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z (%z)")


def run(command: list[str | Path], log_path: Path, cwd: Path = REPO) -> None:
    rendered = [str(item) for item in command]
    with log_path.open("w") as log:
        log.write("$ " + " ".join(shlex.quote(item) for item in rendered) + "\n\n")
        log.flush()
        subprocess.run(rendered, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=True)


def clean_module_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def executable_from_env(env_name: str, fallback: str) -> Path | None:
    configured = os.environ.get(env_name, fallback)
    if os.sep in configured:
        path = Path(configured)
        return path if path.exists() else None
    found = shutil.which(configured)
    return Path(found) if found else None


def require_executable(env_name: str, fallback: str) -> Path:
    path = executable_from_env(env_name, fallback)
    if path is None:
        raise SystemExit(
            f"required executable '{fallback}' was not found; set {env_name} to override"
        )
    return path


def resolve_diamond() -> tuple[DiamondTools | None, str]:
    diamond = executable_from_env("DIAMOND", "diamond")
    if diamond is None:
        return None, "diamond executable was not found"

    diamond = diamond.resolve()
    diamond_env = diamond.parent / "diamond_env"
    pnmainc = shutil.which("pnmainc") or shutil.which(str(diamond.parent / "pnmainc"))
    if not diamond_env.is_file() and pnmainc is None:
        return None, f"neither {diamond_env} nor pnmainc is available"

    return DiamondTools(diamond=diamond, diamond_env=diamond_env if diamond_env.is_file() else None), ""


def rtl_sources(spec: ModuleSpec) -> list[Path]:
    if spec.kind == "pack":
        return [REPO / "float" / "hdl" / "_zkf_pack.v"]
    if spec.kind == "mul":
        return [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            REPO / "float" / "hdl" / "zkf_mul.v",
        ]
    if spec.kind == "add":
        return [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            REPO / "float" / "hdl" / "zkf_add.v",
        ]
    if spec.kind == "addsub":
        return [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            REPO / "float" / "hdl" / "zkf_add.v",
            REPO / "float" / "hdl" / "zkf_addsub.v",
        ]
    if spec.kind == "div_core":
        return [REPO / "float" / "hdl" / "_zkf_div_core.v"]
    if spec.kind == "div":
        return [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            REPO / "float" / "hdl" / "_zkf_div_core.v",
            REPO / "float" / "hdl" / "zkf_div.v",
        ]
    if spec.kind == "cmp":
        return [
            REPO / "float" / "hdl" / "zkf_cmp_comb.v",
            REPO / "float" / "hdl" / "zkf_cmp.v",
        ]
    if spec.kind == "sort":
        return [
            REPO / "float" / "hdl" / "zkf_cmp_comb.v",
            REPO / "float" / "hdl" / "zkf_sort.v",
        ]
    if spec.kind == "mul_ilog2_const":
        return [REPO / "float" / "hdl" / "zkf_mul_ilog2_const.v"]
    if spec.kind == "from_int":
        return [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            REPO / "float" / "hdl" / "zkf_from_int.v",
        ]
    if spec.kind == "to_int":
        return [REPO / "float" / "hdl" / "zkf_to_int.v"]
    if spec.kind == "resize":
        return [
            REPO / "float" / "hdl" / "_zkf_pack.v",
            REPO / "float" / "hdl" / "zkf_resize.v",
        ]
    raise ValueError(f"unsupported module kind: {spec.kind}")


def div_qfrac(spec: ModuleSpec) -> int:
    qfrac_base = spec.wman + 2
    return qfrac_base + (qfrac_base % 2)


def register_stages(spec: ModuleSpec) -> int:
    qfrac_base = spec.wman + 2
    qfrac = qfrac_base + (qfrac_base % 2)
    div_core_stages = 2 + (qfrac // 2)

    if spec.kind == "pack":
        return 2
    if spec.kind == "mul":
        return 3
    if spec.kind in {"add", "addsub"}:
        return 6
    if spec.kind == "div_core":
        return div_core_stages
    if spec.kind == "div":
        return div_core_stages + 2
    if spec.kind in {"cmp", "sort"}:
        return 1
    if spec.kind == "mul_ilog2_const":
        return 1
    if spec.kind in {"from_int", "to_int"}:
        return 3
    if spec.kind == "resize":
        # 1 stage on the widen-only fast path, 2 stages when _zkf_pack is involved.
        if spec.wman_out >= spec.wman_in and spec.wexp_out >= spec.wexp_in:
            return 1
        return 2
    raise ValueError(f"unsupported module kind: {spec.kind}")


def format_register_stages(stages: int) -> str:
    suffix = "stage" if stages == 1 else "stages"
    return f"{stages} {suffix}"


def params(spec: ModuleSpec) -> str:
    if spec.kind == "pack":
        return (
            f"WEXP={spec.wexp}, WMAN={spec.wman}, "
            f"WEXP_UNBIASED={spec.wexp_unbiased}"
        )
    if spec.kind in {"div_core", "div"}:
        return (
            f"WEXP={spec.wexp}, WMAN={spec.wman}, "
            f"QFRAC={div_qfrac(spec)}, WEXP_UNBIASED={spec.wexp + 2}"
        )
    if spec.kind == "mul_ilog2_const":
        return f"WEXP={spec.wexp}, WMAN={spec.wman}, K={MUL_ILOG2_CONST_K}"
    if spec.kind in {"from_int", "to_int"}:
        return f"WEXP={spec.wexp}, WMAN={spec.wman}, WINT={spec.wint}"
    if spec.kind == "resize":
        return (
            f"WEXP_IN={spec.wexp_in}, WMAN_IN={spec.wman_in}, "
            f"WEXP_OUT={spec.wexp_out}, WMAN_OUT={spec.wman_out}"
        )
    return f"WEXP={spec.wexp}, WMAN={spec.wman}"


def write_pack_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    wexp_unbiased = spec.wexp_unbiased or (spec.wexp + 2)
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     in_valid,
    input  wire                     sign,
    input  wire                     force_zero,
    input  wire                     force_inf,
    input  wire signed [{wexp_unbiased - 1}:0] exp_unbiased,
    input  wire [{spec.wman - 1}:0] significand,
    input  wire                     guard,
    input  wire                     round,
    input  wire                     sticky,
    output wire                     out_valid,
    output wire [{wfull - 1}:0]     y
);
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                            r_in_valid;
    {SYNTH_REG_ATTR}
    reg                            r_sign;
    {SYNTH_REG_ATTR}
    reg                            r_force_zero;
    {SYNTH_REG_ATTR}
    reg                            r_force_inf;
    {SYNTH_REG_ATTR}
    reg signed [{wexp_unbiased - 1}:0] r_exp_unbiased;
    {SYNTH_REG_ATTR}
    reg                 [{spec.wman - 1}:0] r_significand;
    {SYNTH_REG_ATTR}
    reg                            r_guard;
    {SYNTH_REG_ATTR}
    reg                            r_round;
    {SYNTH_REG_ATTR}
    reg                            r_sticky;

    wire                 dut_out_valid;
    wire [{wfull - 1}:0] dut_y;

    {SYNTH_REG_ATTR}
    reg                 r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_y;

    assign out_valid = r_out_valid;
    assign y         = r_y;

    _zkf_pack #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman}),
        .WEXP_UNBIASED({wexp_unbiased})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .sign(r_sign),
        .force_zero(r_force_zero),
        .force_inf(r_force_inf),
        .exp_unbiased(r_exp_unbiased),
        .significand(r_significand),
        .guard(r_guard),
        .round(r_round),
        .sticky(r_sticky),
        .out_valid(dut_out_valid),
        .y(dut_y)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_sign          <= sign;
        r_force_zero    <= force_zero;
        r_force_inf     <= force_inf;
        r_exp_unbiased  <= exp_unbiased;
        r_significand   <= significand;
        r_guard         <= guard;
        r_round         <= round;
        r_sticky        <= sticky;
        r_y             <= dut_y;
    end
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
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_b;

    wire                 dut_out_valid;
    wire [{wfull - 1}:0] dut_y;

    {SYNTH_REG_ATTR}
    reg                 r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_y;

    assign out_valid = r_out_valid;
    assign y         = r_y;

    zkf_mul #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .b(r_b),
        .out_valid(dut_out_valid),
        .y(dut_y)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a <= a;
        r_b <= b;
        r_y <= dut_y;
    end
endmodule

`default_nettype wire
"""
    )


def write_add_wrapper(spec: ModuleSpec, path: Path) -> None:
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
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_b;

    wire                 dut_out_valid;
    wire [{wfull - 1}:0] dut_y;

    {SYNTH_REG_ATTR}
    reg                 r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_y;

    assign out_valid = r_out_valid;
    assign y         = r_y;

    zkf_add #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .b(r_b),
        .out_valid(dut_out_valid),
        .y(dut_y)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a <= a;
        r_b <= b;
        r_y <= dut_y;
    end
endmodule

`default_nettype wire
"""
    )


def write_addsub_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire [{wfull - 1}:0] a,
    input  wire [{wfull - 1}:0] b,
    input  wire                 op_sub,
    output wire                 out_valid,
    output wire [{wfull - 1}:0] y
);
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_b;
    {SYNTH_REG_ATTR}
    reg                 r_op_sub;

    wire                 dut_out_valid;
    wire [{wfull - 1}:0] dut_y;

    {SYNTH_REG_ATTR}
    reg                 r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_y;

    assign out_valid = r_out_valid;
    assign y         = r_y;

    zkf_addsub #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .b(r_b),
        .op_sub(r_op_sub),
        .out_valid(dut_out_valid),
        .y(dut_y)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a      <= a;
        r_b      <= b;
        r_op_sub <= op_sub;
        r_y      <= dut_y;
    end
endmodule

`default_nettype wire
"""
    )


def write_div_core_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    wexp_unbiased = spec.wexp + 2
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
    output wire                     force_zero,
    output wire                     force_inf,
    output wire signed [{wexp_unbiased - 1}:0] exp_unbiased,
    output wire [{spec.wman - 1}:0] significand,
    output wire                     guard,
    output wire                     round,
    output wire                     sticky,
    output wire                     div0,
    output wire [{spec.wman - 1}:0] partial_rem
);
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_b;

    wire                            dut_out_valid;
    wire                            dut_sign;
    wire                            dut_force_zero;
    wire                            dut_force_inf;
    wire signed [{wexp_unbiased - 1}:0] dut_exp_unbiased;
    wire                 [{spec.wman - 1}:0] dut_significand;
    wire                            dut_guard;
    wire                            dut_round;
    wire                            dut_sticky;
    wire                            dut_div0;
    wire                 [{spec.wman - 1}:0] dut_partial_rem;

    {SYNTH_REG_ATTR}
    reg                            r_out_valid;
    {SYNTH_REG_ATTR}
    reg                            r_sign;
    {SYNTH_REG_ATTR}
    reg                            r_force_zero;
    {SYNTH_REG_ATTR}
    reg                            r_force_inf;
    {SYNTH_REG_ATTR}
    reg signed [{wexp_unbiased - 1}:0] r_exp_unbiased;
    {SYNTH_REG_ATTR}
    reg                 [{spec.wman - 1}:0] r_significand;
    {SYNTH_REG_ATTR}
    reg                            r_guard;
    {SYNTH_REG_ATTR}
    reg                            r_round;
    {SYNTH_REG_ATTR}
    reg                            r_sticky;
    {SYNTH_REG_ATTR}
    reg                            r_div0;
    {SYNTH_REG_ATTR}
    reg                 [{spec.wman - 1}:0] r_partial_rem;

    assign out_valid    = r_out_valid;
    assign sign         = r_sign;
    assign force_zero   = r_force_zero;
    assign force_inf    = r_force_inf;
    assign exp_unbiased = r_exp_unbiased;
    assign significand  = r_significand;
    assign guard        = r_guard;
    assign round        = r_round;
    assign sticky       = r_sticky;
    assign div0         = r_div0;
    assign partial_rem  = r_partial_rem;

    _zkf_div_core #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .b(r_b),
        .out_valid(dut_out_valid),
        .sign(dut_sign),
        .force_zero(dut_force_zero),
        .force_inf(dut_force_inf),
        .exp_unbiased(dut_exp_unbiased),
        .significand(dut_significand),
        .guard(dut_guard),
        .round(dut_round),
        .sticky(dut_sticky),
        .div0(dut_div0),
        .partial_rem(dut_partial_rem)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a             <= a;
        r_b             <= b;
        r_sign          <= dut_sign;
        r_force_zero    <= dut_force_zero;
        r_force_inf     <= dut_force_inf;
        r_exp_unbiased  <= dut_exp_unbiased;
        r_significand   <= dut_significand;
        r_guard         <= dut_guard;
        r_round         <= dut_round;
        r_sticky        <= dut_sticky;
        r_div0          <= dut_div0;
        r_partial_rem   <= dut_partial_rem;
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
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_b;

    wire                 dut_out_valid;
    wire [{wfull - 1}:0] dut_q;
    wire                 dut_div0;

    {SYNTH_REG_ATTR}
    reg                 r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_q;
    {SYNTH_REG_ATTR}
    reg                 r_div0;

    assign out_valid = r_out_valid;
    assign q         = r_q;
    assign div0      = r_div0;

    zkf_div #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .b(r_b),
        .out_valid(dut_out_valid),
        .q(dut_q),
        .div0(dut_div0)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a    <= a;
        r_b    <= b;
        r_q    <= dut_q;
        r_div0 <= dut_div0;
    end
endmodule

`default_nettype wire
"""
    )


def write_cmp_wrapper(spec: ModuleSpec, path: Path) -> None:
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
    output wire                 a_gt_b,
    output wire                 a_eq_b,
    output wire                 a_lt_b
);
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_b;

    wire dut_out_valid;
    wire dut_a_gt_b;
    wire dut_a_eq_b;
    wire dut_a_lt_b;

    {SYNTH_REG_ATTR}
    reg r_out_valid;
    {SYNTH_REG_ATTR}
    reg r_a_gt_b;
    {SYNTH_REG_ATTR}
    reg r_a_eq_b;
    {SYNTH_REG_ATTR}
    reg r_a_lt_b;

    assign out_valid = r_out_valid;
    assign a_gt_b    = r_a_gt_b;
    assign a_eq_b    = r_a_eq_b;
    assign a_lt_b    = r_a_lt_b;

    zkf_cmp #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .b(r_b),
        .out_valid(dut_out_valid),
        .a_gt_b(dut_a_gt_b),
        .a_eq_b(dut_a_eq_b),
        .a_lt_b(dut_a_lt_b)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a      <= a;
        r_b      <= b;
        r_a_gt_b <= dut_a_gt_b;
        r_a_eq_b <= dut_a_eq_b;
        r_a_lt_b <= dut_a_lt_b;
    end
endmodule

`default_nettype wire
"""
    )


def write_sort_wrapper(spec: ModuleSpec, path: Path) -> None:
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
    output wire [{wfull - 1}:0] min,
    output wire [{wfull - 1}:0] max
);
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_b;

    wire                 dut_out_valid;
    wire [{wfull - 1}:0] dut_min;
    wire [{wfull - 1}:0] dut_max;

    {SYNTH_REG_ATTR}
    reg                 r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_min;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_max;

    assign out_valid = r_out_valid;
    assign min       = r_min;
    assign max       = r_max;

    zkf_sort #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .b(r_b),
        .out_valid(dut_out_valid),
        .min(dut_min),
        .max(dut_max)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a   <= a;
        r_b   <= b;
        r_min <= dut_min;
        r_max <= dut_max;
    end
endmodule

`default_nettype wire
"""
    )


def write_mul_ilog2_const_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire [{wfull - 1}:0] a,
    output wire                 out_valid,
    output wire [{wfull - 1}:0] y
);
    // Measurement harness: put real registers on every DUT input and output so the timing report includes
    // paths that would otherwise be reported as unconstrained primary-input/primary-output delays.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;

    wire                 dut_out_valid;
    wire [{wfull - 1}:0] dut_y;

    {SYNTH_REG_ATTR}
    reg                 r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_y;

    assign out_valid = r_out_valid;
    assign y         = r_y;

    zkf_mul_ilog2_const #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman}),
        .K({MUL_ILOG2_CONST_K})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .out_valid(dut_out_valid),
        .y(dut_y)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a <= a;
        r_y <= dut_y;
    end
endmodule

`default_nettype wire
"""
    )


def write_from_int_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    wint = spec.wint
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                          clk,
    input  wire                          rst,
    input  wire                          in_valid,
    input  wire signed [{wint - 1}:0]    a,
    output wire                          out_valid,
    output wire [{wfull - 1}:0]          y
);
    // Measurement harness: register every DUT I/O so the timing report includes register-to-register paths only.
    {SYNTH_REG_ATTR}
    reg                       r_in_valid;
    {SYNTH_REG_ATTR}
    reg signed [{wint - 1}:0] r_a;

    wire                 dut_out_valid;
    wire [{wfull - 1}:0] dut_y;

    {SYNTH_REG_ATTR}
    reg                 r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_y;

    assign out_valid = r_out_valid;
    assign y         = r_y;

    zkf_from_int #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman}),
        .WINT({wint})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .out_valid(dut_out_valid),
        .y(dut_y)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a <= a;
        r_y <= dut_y;
    end
endmodule

`default_nettype wire
"""
    )


def write_to_int_wrapper(spec: ModuleSpec, path: Path) -> None:
    wfull = spec.wexp + spec.wman
    wint = spec.wint
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                          clk,
    input  wire                          rst,
    input  wire                          in_valid,
    input  wire [{wfull - 1}:0]          a,
    output wire                          out_valid,
    output wire signed [{wint - 1}:0]    y
);
    // Measurement harness: register every DUT I/O so the timing report includes register-to-register paths only.
    {SYNTH_REG_ATTR}
    reg                 r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{wfull - 1}:0] r_a;

    wire                       dut_out_valid;
    wire signed [{wint - 1}:0] dut_y;

    {SYNTH_REG_ATTR}
    reg                       r_out_valid;
    {SYNTH_REG_ATTR}
    reg signed [{wint - 1}:0] r_y;

    assign out_valid = r_out_valid;
    assign y         = r_y;

    zkf_to_int #(
        .WEXP({spec.wexp}),
        .WMAN({spec.wman}),
        .WINT({wint})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .out_valid(dut_out_valid),
        .y(dut_y)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a <= a;
        r_y <= dut_y;
    end
endmodule

`default_nettype wire
"""
    )


def write_resize_wrapper(spec: ModuleSpec, path: Path) -> None:
    in_wfull  = spec.wexp_in  + spec.wman_in
    out_wfull = spec.wexp_out + spec.wman_out
    path.write_text(
        f"""`default_nettype none

module {spec.top} (
    input  wire                       clk,
    input  wire                       rst,
    input  wire                       in_valid,
    input  wire [{in_wfull - 1}:0]    a,
    output wire                       out_valid,
    output wire [{out_wfull - 1}:0]   y
);
    // Measurement harness: register every DUT I/O so the timing report includes register-to-register paths only.
    {SYNTH_REG_ATTR}
    reg                    r_in_valid;
    {SYNTH_REG_ATTR}
    reg [{in_wfull - 1}:0] r_a;

    wire                     dut_out_valid;
    wire [{out_wfull - 1}:0] dut_y;

    {SYNTH_REG_ATTR}
    reg                     r_out_valid;
    {SYNTH_REG_ATTR}
    reg [{out_wfull - 1}:0] r_y;

    assign out_valid = r_out_valid;
    assign y         = r_y;

    zkf_resize #(
        .WEXP_IN({spec.wexp_in}),
        .WMAN_IN({spec.wman_in}),
        .WEXP_OUT({spec.wexp_out}),
        .WMAN_OUT({spec.wman_out})
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(r_in_valid),
        .a(r_a),
        .out_valid(dut_out_valid),
        .y(dut_y)
    );

    always @(posedge clk) begin
        if (rst) begin
            r_in_valid  <= 1'b0;
            r_out_valid <= 1'b0;
        end else begin
            r_in_valid  <= in_valid;
            r_out_valid <= dut_out_valid;
        end

        r_a <= a;
        r_y <= dut_y;
    end
endmodule

`default_nettype wire
"""
    )


def write_wrapper(spec: ModuleSpec, path: Path) -> None:
    if spec.kind == "pack":
        write_pack_wrapper(spec, path)
    elif spec.kind == "mul":
        write_mul_wrapper(spec, path)
    elif spec.kind == "add":
        write_add_wrapper(spec, path)
    elif spec.kind == "addsub":
        write_addsub_wrapper(spec, path)
    elif spec.kind == "div_core":
        write_div_core_wrapper(spec, path)
    elif spec.kind == "div":
        write_div_wrapper(spec, path)
    elif spec.kind == "cmp":
        write_cmp_wrapper(spec, path)
    elif spec.kind == "sort":
        write_sort_wrapper(spec, path)
    elif spec.kind == "mul_ilog2_const":
        write_mul_ilog2_const_wrapper(spec, path)
    elif spec.kind == "from_int":
        write_from_int_wrapper(spec, path)
    elif spec.kind == "to_int":
        write_to_int_wrapper(spec, path)
    elif spec.kind == "resize":
        write_resize_wrapper(spec, path)
    else:
        raise ValueError(f"unsupported module kind: {spec.kind}")


def selected_modules(names: str | None) -> list[ModuleSpec]:
    if not names:
        return MODULES
    selected = {name.strip() for name in names.split(",") if name.strip()}
    modules = [spec for spec in MODULES if spec.name in selected]
    missing = selected - {spec.name for spec in modules}
    if missing:
        raise ValueError(f"unknown module names: {', '.join(sorted(missing))}")
    return modules


def flow_modules(args_modules: str | None, flow_env_name: str) -> list[ModuleSpec]:
    names = (
        args_modules
        or os.environ.get(flow_env_name)
        or os.environ.get("FLOAT_SYNTH_MODULES")
        or os.environ.get("SYNTH_MODULES")
    )
    return selected_modules(names)


def relative_or_missing(path: Path | None, base: Path) -> str:
    if path is None:
        return ""
    return str(path.relative_to(base))


def artifact_link(result: dict[str, str], key: str, label: str) -> str:
    target = result.get(key, "")
    if not target:
        return ""
    return f'<a href="{escape(target)}">{escape(label)}</a>'


def joined_links(*links: str) -> str:
    return " | ".join(link for link in links if link)


def parse_metric_value(text: str) -> float | None:
    match = re.search(r"-?[0-9]+(?:\.[0-9]+)?", text)
    return float(match.group(0)) if match else None


def metric_bounds(results: list[dict[str, str]], key: str) -> tuple[float, float] | None:
    values = [value for result in results if (value := parse_metric_value(result.get(key, ""))) is not None]
    return (min(values), max(values)) if values else None


def metric_color_style(
    value_text: str,
    bounds: tuple[float, float] | None,
    higher_is_better: bool,
) -> str:
    value = parse_metric_value(value_text)
    if value is None or bounds is None:
        return ""

    lowest, highest = bounds
    if highest <= lowest:
        normalized_worstness = 0.0
    elif higher_is_better:
        normalized_worstness = (highest - value) / (highest - lowest)
    else:
        normalized_worstness = (value - lowest) / (highest - lowest)

    normalized_worstness = max(0.0, min(1.0, normalized_worstness))
    best_rgb = (207, 237, 216)
    worst_rgb = (246, 205, 205)
    rgb = tuple(
        round(best + (worst - best) * normalized_worstness)
        for best, worst in zip(best_rgb, worst_rgb)
    )
    return f"background-color: #{rgb[0]:02x}{rgb[1]:02x}{rgb[2]:02x};"


def table_cell(text: str, class_name: str = "", style: str = "") -> str:
    attributes = []
    if class_name:
        attributes.append(f'class="{class_name}"')
    if style:
        attributes.append(f'style="{style}"')
    attribute_text = " " + " ".join(attributes) if attributes else ""
    return f"<td{attribute_text}>{escape(text)}</td>"


def metric_cell(
    text: str,
    bounds: tuple[float, float] | None,
    higher_is_better: bool,
    class_name: str = "",
) -> str:
    return table_cell(text, class_name, metric_color_style(text, bounds, higher_is_better))


def read_text(path: Path | None) -> str:
    if path is None or not path.exists():
        return ""
    return path.read_text(errors="replace")


def write_yosys_script(spec: ModuleSpec, wrapper: Path, netlist: Path, script: Path) -> None:
    rtl = rtl_sources(spec) + [wrapper]
    script.write_text(
        "\n".join(
            [f"read_verilog {path}" for path in rtl]
            + [
                f"hierarchy -check -top {spec.top}",
                "proc",
                "opt",
                f"synth_ecp5 -top {spec.top} -noabc9 -abc2 -dff -json {netlist}",
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


def parse_yosys_fmax(nextpnr_log: str, report: dict[str, object]) -> str:
    fmax = report.get("fmax")
    if isinstance(fmax, dict) and fmax:
        achieved = []
        for clock in fmax.values():
            if isinstance(clock, dict) and isinstance(clock.get("achieved"), (int, float)):
                achieved.append(float(clock["achieved"]))
        if achieved:
            return f"{min(achieved):.2f} MHz"

    matches = re.findall(r"Max frequency[^:]*:\s*([0-9.]+)\s*MHz", nextpnr_log)
    if matches:
        return f"{min(float(item) for item in matches):.2f} MHz"
    return "not reported"


def yosys_timing_met(report: dict[str, object]) -> bool:
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


def parse_yosys_slack(nextpnr_log: str, report: dict[str, object]) -> str:
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


def format_nextpnr_resource(
    report: dict[str, object],
    key: str,
    fallback_used: int | None = None,
) -> str:
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
    keys.extend(
        sorted(
            key
            for key, value in cells.items()
            if value and key not in keys and not key.startswith("$")
        )
    )
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
        if any(cell in line for cell in ("TRELLIS_SLICE", "TRELLIS_FF", "LUT4", "PFU", "MULT18X18D", "DP16KD")):
            useful.append(line.strip())
    return "\n".join(useful[-12:]) if useful else "not reported"


def summarize_report_json(report: dict[str, object]) -> str:
    if not report:
        return "nextpnr did not emit a JSON report"
    keys = ", ".join(sorted(report.keys()))
    return f"nextpnr JSON report keys: {keys}"


def synthesize_yosys(spec: ModuleSpec, yosys: Path, nextpnr: Path) -> dict[str, str]:
    module_dir = YOSYS_BUILD / spec.name
    clean_module_dir(module_dir)

    wrapper = module_dir / f"{spec.name}_wrapper.v"
    yosys_script = module_dir / f"{spec.name}.ys"
    netlist = module_dir / f"{spec.name}.json"
    textcfg = module_dir / f"{spec.name}.config"
    nextpnr_report = module_dir / f"{spec.name}_nextpnr.json"
    yosys_log = module_dir / "yosys.log"
    nextpnr_log = module_dir / "nextpnr.log"

    write_wrapper(spec, wrapper)
    write_yosys_script(spec, wrapper, netlist, yosys_script)

    run([yosys, "-s", yosys_script], yosys_log)
    run(
        [
            nextpnr,
            "--85k",
            "--package",
            "CABGA381",
            "--speed",
            DEVICE_SPEED_GRADE,
            "--freq",
            f"{YOSYS_TARGET_FREQ_MHZ:g}",
            "--timing-allow-fail",
            "--lpf-allow-unconstrained",
            "--json",
            netlist,
            "--textcfg",
            textcfg,
            "--report",
            nextpnr_report,
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

    return {
        "name": spec.name,
        "label": spec.label,
        "params": params(spec),
        "register_stages": format_register_stages(register_stages(spec)),
        "fmax": parse_yosys_fmax(nextpnr_text, report_data),
        "target": format_mhz(YOSYS_TARGET_FREQ_MHZ),
        "status": "PASS" if yosys_timing_met(report_data) else "FAIL",
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
        "slack": parse_yosys_slack(nextpnr_text, report_data),
        "json": summarize_report_json(report_data),
        "yosys_log": str(yosys_log.relative_to(YOSYS_BUILD)),
        "nextpnr_log": str(nextpnr_log.relative_to(YOSYS_BUILD)),
        "nextpnr_json": str(nextpnr_report.relative_to(YOSYS_BUILD)),
    }


def write_yosys_html(results: list[dict[str, str]]) -> None:
    rows = []
    details = []
    generated_at = generated_local_time()
    fmax_bounds = metric_bounds(results, "fmax")
    placed_lut4_bounds = metric_bounds(results, "lut_placed")
    for result in results:
        status_class = "pass" if result["status"] == "PASS" else "fail"
        rows.append(
            "<tr>"
            f"<td>{escape(result['label'])}</td>"
            f"<td>{escape(result['params'])}</td>"
            f"<td>{escape(result['register_stages'])}</td>"
            f"<td>{escape(result['target'])}</td>"
            + metric_cell(result["fmax"], fmax_bounds, higher_is_better=True)
            + f"<td><span class=\"status {status_class}\">{escape(result['status'])}</span></td>"
            + f"<td class=\"resource\">{escape(result['lut'])}</td>"
            + metric_cell(result["lut_placed"], placed_lut4_bounds, higher_is_better=False, class_name="resource")
            + f"<td class=\"resource\">{escape(result['ff'])}</td>"
            + f"<td class=\"resource\">{escape(result['comb'])}</td>"
            + f"<td class=\"resource\">{escape(result['carry'])}</td>"
            + f"<td class=\"resource\">{escape(result['pfumx'])}</td>"
            + f"<td class=\"resource\">{escape(result['l6mux21'])}</td>"
            + f"<td class=\"resource\">{escape(result['dsp'])}</td>"
            + f"<td class=\"resource\">{escape(result['alu54'])}</td>"
            + f"<td class=\"resource\">{escape(result['bram'])}</td>"
            + f"<td class=\"resource\">{escape(result['io'])}</td>"
            + "<td>"
            + joined_links(
                artifact_link(result, "nextpnr_log", "nextpnr"),
                artifact_link(result, "yosys_log", "Yosys"),
                artifact_link(result, "nextpnr_json", "JSON"),
            )
            + "</td>"
            "</tr>"
        )
        details.append(
            f"<h2>{escape(result['label'])}</h2>"
            "<h3>Artifacts</h3>"
            "<p>"
            + joined_links(
                artifact_link(result, "nextpnr_log", "nextpnr log"),
                artifact_link(result, "yosys_log", "Yosys log"),
                artifact_link(result, "nextpnr_json", "nextpnr JSON"),
            )
            + "</p>"
            "<h3>Worst Slack</h3>"
            f"<pre>{escape(result['slack'])}</pre>"
            "<h3>Utilization</h3>"
            f"<pre>{escape(result['utilization'])}</pre>"
            "<h3>Yosys Cell Counts</h3>"
            f"<pre>{escape(result['yosys_cells'])}</pre>"
            "<h3>Report JSON</h3>"
            f"<pre>{escape(result['json'])}</pre>"
        )

    (YOSYS_BUILD / "index.html").write_text(
        """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Kulibin Float Yosys Synthesis Report</title>
<style>
body { font-family: sans-serif; margin: 2rem; color: #111; }
table { border-collapse: collapse; margin-bottom: 2rem; }
th, td { border: 1px solid #bbb; padding: 0.35rem 0.6rem; text-align: left; }
th { background: #eee; }
td.resource { white-space: nowrap; }
.status { border-radius: 999px; display: inline-block; font-weight: 700; padding: 0.2rem 0.6rem; }
.status.pass { background: #11823b; color: #fff; }
.status.fail { background: #c82424; color: #fff; }
pre { background: #f6f6f6; border: 1px solid #ddd; padding: 0.8rem; overflow-x: auto; }
</style>
</head>
<body>
<h1>Kulibin Float Yosys Synthesis Report</h1>
"""
        + f"<p>Generated: {escape(generated_at)}</p>"
        + "<p>Flow: Yosys synth_ecp5 with -noabc9 -abc2 -dff, "
        + "nextpnr-ecp5 for LFE5U-85F CABGA381 speed grade "
        + f"{DEVICE_SPEED_GRADE} at {format_mhz(YOSYS_TARGET_FREQ_MHZ)}.</p>"
        + """
<p>Each row is measured through a registered synthesis harness: every DUT input is driven by a wrapper register and
every DUT output is captured by a wrapper register. This makes the reported f max a register-to-register limit instead
of ignoring primary-input or primary-output paths. The harness registers are included in utilization numbers.</p>
<p>Helper-module rows are standalone out-of-context builds. Parent-module rows are flattened and context-optimized, so
helper and parent resource counts are not additive.</p>
<table>
<thead><tr>
<th>Module</th><th>Parameters</th><th>Register stages</th><th>Target</th><th>f max</th><th>Status</th>
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


def synthesize_with_progress(flow_name: str, modules: list[ModuleSpec], synthesize_module) -> list[dict[str, str]]:
    results = []
    total = len(modules)
    for index, spec in enumerate(modules, start=1):
        print(f"[{flow_name}] start {index}/{total}: {spec.name}", flush=True)
        result = synthesize_module(spec)
        results.append(result)
        print(
            f"[{flow_name}] done {index}/{total}: {spec.name}: "
            f"{result['status']}, fmax {result.get('fmax', 'not reported')}",
            flush=True,
        )
    return results


def require_passing_results(flow_name: str, results: list[dict[str, str]], report_path: Path) -> None:
    failed = [result for result in results if result["status"] != "PASS"]
    if not failed:
        return

    print(f"{flow_name} synthesis failed; see {report_path}")
    for result in failed:
        print(
            f"  {result['name']}: status={result['status']} "
            f"target={result.get('target', 'not reported')} fmax={result.get('fmax', 'not reported')}"
        )
    raise SystemExit(1)


def run_yosys_flow(modules: list[ModuleSpec]) -> None:
    yosys = require_executable("YOSYS", "yosys")
    nextpnr = require_executable("NEXTPNR_ECP5", "nextpnr-ecp5")
    YOSYS_BUILD.mkdir(parents=True, exist_ok=True)
    results = synthesize_with_progress("yosys", modules, lambda spec: synthesize_yosys(spec, yosys, nextpnr))
    write_yosys_html(results)
    report_path = YOSYS_BUILD / "index.html"
    print(f"wrote {report_path}")
    require_passing_results("Yosys", results, report_path)


def project_name(spec: ModuleSpec) -> str:
    return (spec.name.lstrip("_") or spec.name.replace("_", "")) + "_diamond"


def path_for_xml(path: Path, base: Path) -> str:
    return os.path.relpath(path, base).replace(os.sep, "/")


def xml_attr(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace('"', "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def write_diamond_lpf(path: Path) -> None:
    path.write_text(
        f"""BLOCK RESETPATHS ;
BLOCK ASYNCPATHS ;
USE PRIMARY NET "clk_c" ;
FREQUENCY NET "clk_c" {DIAMOND_TARGET_FREQ_MHZ:.6f} MHz ;
"""
    )


def write_diamond_strategy(path: Path) -> None:
    properties = {
        "PROP_LST_CarryChain": "True",
        "PROP_LST_CarryChainLength": "0",
        "PROP_LST_DSPStyle": "DSP",
        "PROP_LST_DSPUtil": "100",
        "PROP_LST_EBRUtil": "100",
        "PROP_LST_EdfFrequency": f"{DIAMOND_TARGET_FREQ_MHZ:.0f}",
        "PROP_LST_FIXGATEDCLKS": "True",
        "PROP_LST_FSMEncodeStyle": "Auto",
        "PROP_LST_ForceGSRInfer": "Auto",
        "PROP_LST_IOInsertion": "True",
        "PROP_LST_LoopLimit": "1950",
        "PROP_LST_MaxFanout": "1000",
        "PROP_LST_MuxStyle": "Auto",
        "PROP_LST_NumCriticalPaths": "10",
        "PROP_LST_OptimizeGoal": "Balanced",
        "PROP_LST_PropagatConst": "True",
        "PROP_LST_RAMStyle": "Auto",
        "PROP_LST_ROMStyle": "Auto",
        "PROP_LST_RemoveDupRegs": "True",
        "PROP_LST_ResourceShare": "False",
        "PROP_LST_UseIOReg": "Auto",
        "PROP_LST_UseLPF": "True",
        "PROP_MAPSTA_AnalysisOption": "Standard Setup and Hold Analysis",
        "PROP_MAPSTA_AutoTiming": "True",
        "PROP_MAPSTA_CheckUnconstrainedConns": "False",
        "PROP_MAPSTA_CheckUnconstrainedPaths": "False",
        "PROP_MAPSTA_NumUnconstrainedPaths": "0",
        "PROP_MAPSTA_ReportStyle": "Verbose Timing Report",
        "PROP_MAP_MAPIORegister": "Auto",
        "PROP_MAP_MAPInferGSR": "True",
        "PROP_MAP_RegRetiming": "True",
        "PROP_MAP_TimingDriven": "True",
        "PROP_MAP_TimingDrivenNodeRep": "True",
        "PROP_MAP_TimingDrivenPack": "True",
        "PROP_PARSTA_AnalysisOption": "Standard Setup and Hold Analysis",
        "PROP_PARSTA_AutoTiming": "True",
        "PROP_PARSTA_CheckUnconstrainedConns": "False",
        "PROP_PARSTA_CheckUnconstrainedPaths": "False",
        "PROP_PARSTA_NumUnconstrainedPaths": "0",
        "PROP_PARSTA_ReportStyle": "Verbose Timing Report",
        "PROP_PARSTA_SpeedForHoldAnalysis": "m",
        "PROP_PARSTA_SpeedForSetupAnalysis": "default",
        "PROP_PARSTA_WordCasePaths": "10",
        "PROP_PAR_DisableTDParDes": "False",
        "PROP_PAR_EffortParDes": "5",
        "PROP_PAR_MultiSeedSortMode": "Worst Slack",
        "PROP_PAR_NewRouteParDes": "NBR",
        "PROP_PAR_PARClockSkew": "Off",
        "PROP_PAR_PlcIterParDes": "2",
        "PROP_PAR_PlcStCostTblParDes": "1",
        "PROP_PAR_PrefErrorOut": "False",
        "PROP_PAR_RoutePassParDes": str(DIAMOND_ROUTE_PASSES),
        "PROP_PAR_RoutingCDP": "Auto",
        "PROP_PAR_RoutingCDR": "1",
        "PROP_PAR_RunParWithTrce": "True",
        "PROP_PAR_RunTimeReduction": "False",
        "PROP_PAR_SaveBestRsltParDes": "1",
        "PROP_PAR_StopZero": "False",
        "PROP_PAR_parHold": "On",
        "PROP_PAR_parPathBased": "On",
        "PROP_SYN_EdfArea": "False",
        "PROP_SYN_EdfFrequency": f"{DIAMOND_TARGET_FREQ_MHZ:.0f}",
        "PROP_SYN_EdfGSR": "False",
        "PROP_SYN_EdfInsertIO": "False",
        "PROP_SYN_EdfRunRetiming": "Pipelining and Retiming",
        "PROP_SYN_EdfVerilogInput": "Verilog 2001",
        "PROP_SYN_UseLPF": "True",
    }
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<!DOCTYPE strategy>",
        '<Strategy version="1.0" predefined="0" description="" label="DiamondLseMaxTiming">',
    ]
    lines.extend(
        f'    <Property name="{xml_attr(name)}" value="{xml_attr(value)}" time="0"/>'
        for name, value in properties.items()
    )
    lines.append("</Strategy>")
    path.write_text("\n".join(lines) + "\n")


def write_diamond_ldf(spec: ModuleSpec, wrapper: Path, lpf: Path, sty: Path, ldf: Path) -> None:
    project_dir = ldf.parent
    sources = [wrapper] + rtl_sources(spec)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        (
            f'<BaliProject version="3.2" title="{xml_attr(project_name(spec))}" '
            f'device="{xml_attr(DIAMOND_DEVICE)}" default_implementation="impl1">'
        ),
        "    <Options/>",
        '    <Implementation title="impl1" dir="impl1" description="impl1" synthesis="lse" '
        'default_strategy="Strategy1">',
        f'        <Options def_top="{xml_attr(spec.top)}">',
        f'            <Option name="top" value="{xml_attr(spec.top)}"/>',
        "        </Options>",
    ]
    for source in sources:
        rel = xml_attr(path_for_xml(source, project_dir))
        if source == wrapper:
            lines.extend(
                [
                    f'        <Source name="{rel}" type="Verilog" type_short="Verilog">',
                    f'            <Options top_module="{xml_attr(spec.top)}"/>',
                    "        </Source>",
                ]
            )
        else:
            lines.extend(
                [
                    f'        <Source name="{rel}" type="Verilog" type_short="Verilog">',
                    "            <Options/>",
                    "        </Source>",
                ]
            )
    lines.extend(
        [
            f'        <Source name="{xml_attr(path_for_xml(lpf, project_dir))}" '
            'type="Logic Preference" type_short="LPF">',
            "            <Options/>",
            "        </Source>",
            "    </Implementation>",
            f'    <Strategy name="Strategy1" file="{xml_attr(path_for_xml(sty, project_dir))}"/>',
            "</BaliProject>",
        ]
    )
    ldf.write_text("\n".join(lines) + "\n")


def write_diamond_tcl(project_file: Path, tcl: Path) -> None:
    project = str(project_file).replace("\\", "/")
    tcl.write_text(
        f"""proc fail {{message}} {{
    puts stderr $message
    exit 1
}}
if {{[catch {{prj_project open "{project}"}} result]}} {{
    fail $result
}}
if {{[catch {{prj_run PAR -impl impl1 -forceAll}} result]}} {{
    catch {{prj_project close}}
    fail $result
}}
if {{[catch {{prj_project close}} result]}} {{
    fail $result
}}
exit 0
"""
    )


def run_diamond_console(tools: DiamondTools, tcl: Path, log_path: Path) -> None:
    bindir = shlex.quote(str(tools.diamond.parent))
    env_path = shlex.quote(str(tools.diamond_env)) if tools.diamond_env is not None else ""
    source_env = f'source {env_path}' if env_path else ':'
    script = f"""
set -euo pipefail
bindir={bindir}
export PATH="$bindir:$PATH"
set +u
{source_env}
set -u
command -v pnmainc >/dev/null 2>&1 || {{
    echo "error: Diamond Tcl console 'pnmainc' was not found" >&2
    exit 1
}}
pnmainc < {shlex.quote(str(tcl))}
"""
    run(["bash", "-lc", script], log_path)


def find_diamond_report_paths(module_dir: Path) -> DiamondReportPaths:
    impl_dir = module_dir / "impl1"
    twrs = sorted(impl_dir.glob("*.twr"))
    lse_twrs = [path for path in twrs if path.name.endswith("_lse.twr")]
    post_twrs = [path for path in twrs if path not in lse_twrs]
    return DiamondReportPaths(
        twr=post_twrs[-1] if post_twrs else None,
        lse_twr=lse_twrs[-1] if lse_twrs else None,
        mrp=next(iter(sorted(impl_dir.glob("*.mrp"))), None),
        par=next(iter(sorted(impl_dir.glob("*.par"))), None),
    )


def parse_diamond_fmax_mhz(twr_text: str) -> float | None:
    matches = re.findall(
        r"(?:Report|Warning):\s+([0-9.]+)\s*MHz is the maximum frequency",
        twr_text,
        re.IGNORECASE,
    )
    if matches:
        return min(float(match) for match in matches)
    return None


def parse_diamond_timing_errors(twr_text: str) -> tuple[int | None, int | None]:
    match = re.search(r"Timing errors:\s+([0-9]+)\s+\(setup\),\s+([0-9]+)\s+\(hold\)", twr_text)
    if match:
        return int(match.group(1)), int(match.group(2))
    match = re.search(r"Timing errors:\s+([0-9]+)\s+Score:", twr_text)
    if match:
        return int(match.group(1)), None
    return None, None


def parse_diamond_resource(pattern: str, text: str) -> str:
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        return "not reported"
    used = int(match.group(1))
    available = int(match.group(2))
    return f"{used}/{available} ({100.0 * used / available:.2f}%)"


def parse_diamond_par_summary(par_text: str, key: str) -> int | None:
    match = re.search(rf"PAR_SUMMARY::{re.escape(key)}\s*=\s*([0-9]+)", par_text)
    return int(match.group(1)) if match else None


def format_optional_fmax(value: float | None) -> str:
    return f"{value:.2f} MHz" if value is not None else "not reported"


def format_diamond_slack_from_fmax(fmax_mhz: float | None) -> str:
    if fmax_mhz is None or fmax_mhz <= 0.0:
        return "not reported"
    slack_ns = (1000.0 / DIAMOND_TARGET_FREQ_MHZ) - (1000.0 / fmax_mhz)
    return f"{slack_ns:.3f} ns"


def synthesize_diamond(spec: ModuleSpec, tools: DiamondTools) -> dict[str, str]:
    module_dir = DIAMOND_BUILD / spec.name
    clean_module_dir(module_dir)

    wrapper = module_dir / f"{spec.name}_wrapper.v"
    lpf = module_dir / f"{project_name(spec)}.lpf"
    sty = module_dir / f"{project_name(spec)}.sty"
    ldf = module_dir / f"{project_name(spec)}.ldf"
    tcl = module_dir / "run_diamond.tcl"
    diamond_log = module_dir / "diamond.log"

    write_wrapper(spec, wrapper)
    write_diamond_lpf(lpf)
    write_diamond_strategy(sty)
    write_diamond_ldf(spec, wrapper, lpf, sty, ldf)
    write_diamond_tcl(ldf, tcl)
    run_diamond_console(tools, tcl, diamond_log)

    reports = find_diamond_report_paths(module_dir)
    twr_text = read_text(reports.twr)
    mrp_text = read_text(reports.mrp)
    par_text = read_text(reports.par)
    fmax = parse_diamond_fmax_mhz(twr_text)
    setup_errors, hold_errors = parse_diamond_timing_errors(twr_text)
    unrouted = parse_diamond_par_summary(par_text, "Number of unrouted conns")
    par_errors = parse_diamond_par_summary(par_text, "Number of errors")
    route_clean = unrouted in {None, 0} and par_errors in {None, 0}
    timing_clean = (
        fmax is not None
        and fmax >= DIAMOND_TARGET_FREQ_MHZ
        and setup_errors in {None, 0}
        and hold_errors in {None, 0}
    )

    return {
        "name": spec.name,
        "label": spec.label,
        "params": params(spec),
        "register_stages": format_register_stages(register_stages(spec)),
        "target": format_mhz(DIAMOND_TARGET_FREQ_MHZ),
        "fmax": format_optional_fmax(fmax),
        "slack": format_diamond_slack_from_fmax(fmax),
        "status": "PASS" if route_clean and timing_clean else "FAIL",
        "registers": parse_diamond_resource(r"Number of registers:\s+([0-9]+) out of ([0-9]+)", mrp_text),
        "lut4": parse_diamond_resource(r"Number of LUT4s:\s+([0-9]+) out of ([0-9]+)", mrp_text),
        "slice": parse_diamond_resource(r"SLICE\s+([0-9]+)/([0-9]+)", par_text),
        "pio": parse_diamond_resource(r"PIO \(prelim\)\s+([0-9]+)/([0-9]+)", par_text),
        "diamond_log": relative_or_missing(diamond_log, DIAMOND_BUILD),
        "twr": relative_or_missing(reports.twr, DIAMOND_BUILD),
        "lse_twr": relative_or_missing(reports.lse_twr, DIAMOND_BUILD),
        "mrp": relative_or_missing(reports.mrp, DIAMOND_BUILD),
        "par": relative_or_missing(reports.par, DIAMOND_BUILD),
        "ldf": relative_or_missing(ldf, DIAMOND_BUILD),
        "sty": relative_or_missing(sty, DIAMOND_BUILD),
        "lpf": relative_or_missing(lpf, DIAMOND_BUILD),
        "setup_errors": "not reported" if setup_errors is None else str(setup_errors),
        "hold_errors": "not reported" if hold_errors is None else str(hold_errors),
        "unrouted": "not reported" if unrouted is None else str(unrouted),
        "par_errors": "not reported" if par_errors is None else str(par_errors),
    }


def write_diamond_html(results: list[dict[str, str]]) -> None:
    rows = []
    details = []
    generated_at = generated_local_time()
    fmax_bounds = metric_bounds(results, "fmax")
    slice_bounds = metric_bounds(results, "slice")
    for result in results:
        status_class = "pass" if result["status"] == "PASS" else "fail"
        rows.append(
            "<tr>"
            f"<td>{escape(result['label'])}</td>"
            f"<td>{escape(result['params'])}</td>"
            f"<td>{escape(result['register_stages'])}</td>"
            f"<td>{escape(result['target'])}</td>"
            + metric_cell(result["fmax"], fmax_bounds, higher_is_better=True)
            + f"<td>{escape(result['slack'])}</td>"
            + f"<td><span class=\"status {status_class}\">{escape(result['status'])}</span></td>"
            + f"<td class=\"resource\">{escape(result['lut4'])}</td>"
            + f"<td class=\"resource\">{escape(result['registers'])}</td>"
            + metric_cell(result["slice"], slice_bounds, higher_is_better=False, class_name="resource")
            + f"<td class=\"resource\">{escape(result['pio'])}</td>"
            + "<td>"
            + joined_links(
                artifact_link(result, "twr", "TRACE"),
                artifact_link(result, "par", "PAR"),
                artifact_link(result, "mrp", "MAP"),
                artifact_link(result, "diamond_log", "Diamond"),
            )
            + "</td>"
            "</tr>"
        )
        details.append(
            f"<h2>{escape(result['label'])}</h2>"
            "<h3>Status</h3>"
            "<pre>"
            f"setup errors: {escape(result['setup_errors'])}\n"
            f"hold errors:  {escape(result['hold_errors'])}\n"
            f"unrouted:     {escape(result['unrouted'])}\n"
            f"PAR errors:   {escape(result['par_errors'])}"
            "</pre>"
            "<h3>Artifacts</h3>"
            "<p>"
            + joined_links(
                artifact_link(result, "ldf", "project"),
                artifact_link(result, "sty", "strategy"),
                artifact_link(result, "lpf", "preferences"),
                artifact_link(result, "twr", "TRACE"),
                artifact_link(result, "lse_twr", "LSE timing"),
                artifact_link(result, "par", "PAR"),
                artifact_link(result, "mrp", "MAP"),
                artifact_link(result, "diamond_log", "Diamond log"),
            )
            + "</p>"
        )

    (DIAMOND_BUILD / "index.html").write_text(
        """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Kulibin Float Diamond/LSE Synthesis Report</title>
<style>
body { font-family: sans-serif; margin: 2rem; color: #111; }
table { border-collapse: collapse; margin-bottom: 2rem; }
th, td { border: 1px solid #bbb; padding: 0.35rem 0.6rem; text-align: left; }
th { background: #eee; }
td.resource { white-space: nowrap; }
.status { border-radius: 999px; display: inline-block; font-weight: 700; padding: 0.2rem 0.6rem; }
.status.pass { background: #11823b; color: #fff; }
.status.fail { background: #c82424; color: #fff; }
pre { background: #f6f6f6; border: 1px solid #ddd; padding: 0.8rem; overflow-x: auto; }
</style>
</head>
<body>
<h1>Kulibin Float Diamond/LSE Synthesis Report</h1>
"""
        + f"<p>Generated: {escape(generated_at)}</p>"
        + f"<p>Flow: Lattice Diamond LSE for {escape(DIAMOND_DEVICE)} at "
        + f"{format_mhz(DIAMOND_TARGET_FREQ_MHZ)}. LSE optimization goal is Balanced, "
        + "MAP register retiming is enabled, PAR placement effort is 5, and routing passes are "
        + f"{DIAMOND_ROUTE_PASSES}.</p>"
        + """
<p>Each row is measured through a registered synthesis harness: every DUT input is driven by a wrapper register and
every DUT output is captured by a wrapper register. This makes the reported f max a register-to-register limit instead
of ignoring primary-input or primary-output paths. The harness registers are included in utilization numbers.</p>
<p>Helper-module rows are standalone out-of-context builds. Parent-module rows are flattened and context-optimized, so
helper and parent resource counts are not additive.</p>
<table>
<thead><tr>
<th>Module</th><th>Parameters</th><th>Register stages</th><th>Target</th><th>f max</th><th>Slack</th><th>Status</th>
<th>LUT4</th><th>Registers</th><th>Slice</th><th>PIO</th><th>Logs</th>
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


def run_diamond_flow(modules: list[ModuleSpec]) -> bool:
    tools, reason = resolve_diamond()
    if tools is None:
        print(f"skipping Diamond/LSE synthesis: {reason}")
        return False

    DIAMOND_BUILD.mkdir(parents=True, exist_ok=True)
    results = synthesize_with_progress("diamond", modules, lambda spec: synthesize_diamond(spec, tools))
    write_diamond_html(results)
    report_path = DIAMOND_BUILD / "index.html"
    print(f"wrote {report_path}")
    require_passing_results("Diamond/LSE", results, report_path)
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--flow",
        choices=("all", "yosys", "diamond"),
        default="all",
        help="synthesis flow to run; 'all' runs required Yosys and optional Diamond",
    )
    parser.add_argument(
        "--modules",
        help="comma-separated module names to synthesize; defaults to all configured float modules",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.flow in {"all", "yosys"}:
        run_yosys_flow(flow_modules(args.modules, "YOSYS_MODULES"))
    if args.flow in {"all", "diamond"}:
        run_diamond_flow(flow_modules(args.modules, "DIAMOND_MODULES"))


if __name__ == "__main__":
    main()
