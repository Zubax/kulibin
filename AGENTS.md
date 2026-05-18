# Repository Guidelines

Kulibin is a reusable HDL library where modules are loosely grouped per function; many of them are usable standalone, some depend on others. RTL code lives under `hdl/`, simulations under `tb/`. Analysis and design-helper scripts are Python files are provided for some groups. Generated FuseSoC and simulator output belongs in `build/` and should not be edited by hand.

Read the `README.md`.

## Commands

- `make library`: registers this checkout as the local FuseSoC library `kulibin`.
- `make verify`: runs every configured simulation target with FuseSoC and Icarus Verilog.
- `make lint`: runs `verible-verilog-lint` over all `.v` files outside `build/`.
- `make clean`: removes generated build artifacts.
- `fusesoc run --target=sim zubax:kulibin:nco`: runs one core target; use `sim_<name>` targets where defined, such as `sim_round_signed`.
- `./hierarchy.py`: run this when changing the set of modules or their interdependencies to update the diagram in the README.md.

Python helper scripts commonly require NumPy, SciPy, SymPy, and matplotlib.

## Conventions

### Reset strategy

Use synchronous active-high reset for stream control only: validity flags, state-machine state, and other control
registers that define whether an output transaction is meaningful. Avoid resetting pure datapath registers whose
contents are ignored while their associated valid flag is deasserted. This keeps high-fanout reset nets out of wide
payload cones, reduces control-set pressure, and gives synthesis/place-and-route more freedom to retime and optimize
pipeline registers.

One subtle point: do not write the datapath assignment only in the reset-else branch, as it still makes data depend on
rst because the register is held during reset. A better strategy is to make datapath manipulation reset-unconditional
and only keep the control signals under rst/else.

References:

- AMD UG949, "When and Where to Use a Reset":
  <https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/When-and-Where-to-Use-a-Reset>
- Intel Hyperflex Architecture High-Performance Design Handbook, "Synchronous Resets Summary":
  <https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/synchronous-resets-summary?contentId=vgtR8yUs_Z5DH0ApHJFiTQ>
- Intel Hyperflex Architecture High-Performance Design Handbook, "Reset Strategies":
  <https://docs.altera.com/r/docs/683353/25.1.1/hyperflex-architecture-high-performance-design-handbook/reset-strategies?contentId=gzd92HdsL40qZGHurB0ezg>

### Language

Verilog style: 4-space indentation, concise module names, snake_case files and directories, and uppercase parameter/localparam names where practical.
Keep line length at or below 120 columns. Comment block lines should utilize the 120 column limit well, avoiding overly short lines.

Verilog testbenches should be named `<module>_tb.v`, include explicit assertions using `$fatal` or the local `` `REQUIRE `` macro pattern, and declare `` `timescale `` plus `` `default_nettype none `` when adding new benches.
FuseSoC core names follow `zubax:kulibin:<module>:0`; target names use `sim` or `sim_<case>`.

The following constructs are banned in synthesizable Verilog (fine in testbenches):

- Any form of `always` except for `always @(posedge clk)`.
- Blocking register assignment.
- Functions.

In synthesizable code, prefer `case` statements over nested ternary operators unless there are contraindications.

In complex modules, it is best to avoid a large number of named nets that are only used once; this does not help readability but rather the opposite.


## Verification

Add or update a testbench for behavioral changes to RTL. Keep focused unit benches near the module under `tb/`, and register new filesets/targets in the module `.core` file. Before submitting changes, run `make lint` and `make verify`; for narrow edits, also run the affected `fusesoc run --target=...` command directly during development.

Generated reports must be written in rich and colorful HTML format, not Markdown.
