# Repository Guidelines

Kulibin is a reusable HDL library where modules are loosely grouped per function; many of them are usable standalone, some depend on others. RTL code lives under `hdl/`, simulations under `tb/`. Analysis and design-helper scripts are Python files are provided for some groups. Generated FuseSoC and simulator output belongs in `build/` and should not be edited by hand.

Read the `README.md`.

## Commands

- `make library`: registers this checkout as the local FuseSoC library `kulibin`.
- `make verify`: runs every configured simulation target with FuseSoC and Icarus Verilog.
- `make lint`: runs `verible-verilog-lint` over all `.v` files outside `build/`.
- `make clean`: removes generated build artifacts.
- `fusesoc run --target=sim zubax:kulibin:nco`: runs one core target; use `sim_<name>` targets where defined, such as `sim_round_signed`.

Python helper scripts commonly require NumPy, SciPy, SymPy, and matplotlib.

## Conventions

Use Verilog consistent with the existing RTL: 4-space indentation, concise module names, snake_case files and directories, and uppercase parameter/localparam names where practical. Keep line length at or below 120 columns, matching `.rules.verible_lint`. Testbenches should be named `<module>_tb.v`, include explicit assertions using `$fatal` or the local `` `REQUIRE `` macro pattern, and declare `` `timescale `` plus `` `default_nettype none `` when adding new benches. FuseSoC core names follow `zubax:kulibin:<module>:0`; target names use `sim` or `sim_<case>`.

## Verification

Add or update a testbench for behavioral changes to RTL. Keep focused unit benches near the module under `tb/`, and register new filesets/targets in the module `.core` file. Before submitting changes, run `make lint` and `make verify`; for narrow edits, also run the affected `fusesoc run --target=...` command directly during development.
