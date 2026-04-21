<div align="center">

<img src="https://zubax.com/static/assets/logos/zubax-logo-modern.svg" width="130px">

<h1>Kulibin HDL library</h1>

_reusable HDL modules_

[![verify](https://github.com/Zubax/kulibin/actions/workflows/verify.yml/badge.svg)](https://github.com/Zubax/kulibin/actions/workflows/verify.yml)
[![Website](https://img.shields.io/badge/website-zubax.com-black?color=e00000)](https://zubax.com/)
[![Forum](https://img.shields.io/discourse/https/forum.zubax.com/users.svg?logo=discourse&color=e00000)](https://forum.zubax.com)

</div>

---

Kulibin is a loose collection of reusable HDL modules.
Auxiliary Python scripts are provided for analysis and parameter derivation;
they commonly require NumPy, SciPy, SymPy, matplotlib.
Higher-level modules serve as usage examples for the lower-level ones.

## Verification

Each module is wrapped in a FuseSoC `.core` file. All testbenches are run locally with:

    make verify

which invokes `fusesoc run --target=sim[_<name>] zubax:kulibin:<module>` for every registered target.

See CI files in `.github/`.
