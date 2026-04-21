# Kulibin HDL module library

A collection of reusable HDL modules.

Python scripts are provided for analysis and parameter derivation.
They commonly require NumPy, SciPy, SymPy, matplotlib.

## TODO

Integrate a verification suite that runs in CI.

The FIR tests are currently dependent on generated kernel coefficient files `*.memb`,
which is done in the Python scripts. These need to be invoked during verification.
