#!/usr/bin/env python3

"""
Plot the frequency response of a Verilog memb FIR kernel.
"""

import sys
from pathlib import Path

from fir import fir_kernel_from_verilog_fixpoint, fir_plot


def main() -> None:
    kernel_file = Path(sys.argv[1]).resolve()
    f_s = float(sys.argv[2]) if len(sys.argv) > 2 else 1
    q, kernel = fir_kernel_from_verilog_fixpoint(kernel_file)
    output = kernel_file.with_suffix(".response.png")
    fir_plot(
        f_s=f_s,
        kernel_real=None,
        kernel_quantized=kernel,
        title=f"kernel={kernel_file.stem} q{q[0]}.{q[1]}",
        out=str(output),
    )
    print(output)


if __name__ == "__main__":
    main()
