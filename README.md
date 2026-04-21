# Kulibin HDL module library

A collection of reusable HDL modules.

Python scripts are provided for analysis and parameter derivation.
They commonly require NumPy, SciPy, SymPy, matplotlib.

Higher-level modules serve as usage examples for the lower-level ones;
e.g., there is a sigma-delta ADC to PWM conversion module that aggregates a large number of submodules.

## Verification

Each module is wrapped in a FuseSoC `.core` file. All testbenches are run locally with:

    make verify

which invokes `fusesoc run --target=sim[_<name>] zubax:kulibin:<module>` for every registered target.

See CI files in `.github/`.
