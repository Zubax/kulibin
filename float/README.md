# Zubax Kuibin floating point

A small and FPGA-friendly floating point format that is similar to IEEE 754 but intentionally omits support for NaN, subnormals, exceptions, and rounding modes other than round-to-nearest, ties-to-even. Numbers underflow to zero instead of subnormals. Only one canonical positive zero representation exists.

The bit layout is identical to IEEE 754: sign, exponent, and the significand with the MSb omitted. See `zkf.py` for the encoding rules.

## Usage

The `zkf_*` modules implement various operators. Unless specified otherwise, all modules are zero-bubble throughput-1 pipelines, and all have registered inputs, allowing direct connection to BRAM, which is useful in register files etc. Two two parameters are WEXP and WMAN setting the bit width of the biased exponent and the significand; the most significant bit of the significand is not stored, but there is a sign bit, so the total bit width is simply WFULL=WEXP+WMAN.

## Notable sizes

### WEXP=? WMAN=18

An FPGA-friendly format because modern DSP-enabled FPGAs usually implement 18x18 bit multipliers, which means that a narrower mantissa is unlikely to save much resources or nontrivially improve timings as long as hardware multipliers are used, while going a single bit higher may explode the footprint.

One can stay within 24 bits total by choosing WEXP=6:

    WEXP=6 WMAN=18 WFRAC=17 WFULL=24 BIAS=31
    lowest     = 1/1073741824 ≈ 9.313e-10
    max        = 0xffff_c000  ≈ 4.295e+09
    ε          = 1/131072     ≈ 7.629e-06

### WEXP=7 WMAN=17

An MCU-friendly format with clean byte alignment: 8 bits for the sign and the exponent, 16 bits for the fractional bits.

    WEXP=7 WMAN=17 WFRAC=16 WFULL=24 BIAS=63
    lowest     = 1/4611686018427387904 ≈ 2.168e-19
    max        = 0xffff_8000_0000_0000 ≈ 1.845e+19
    ε          = 1/65536               ≈ 1.526e-05

### IEEE 754-like

ZKF offers limited compatibility with IEEE 754 so while it can match the bit layout, not all states are mappable between the formats.

- WEXP=5  WMAN=11: IEEE 754 binary16-like
- WEXP=8  WMAN=24: IEEE 754 binary32-like
- WEXP=11 WMAN=53: IEEE 754 binary64-like
