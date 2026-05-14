# Zubax Kuibin floating point

A small and FPGA-friendly floating point format that is similar to IEEE 754 but intentionally omits support for NaN, subnormals, exceptions, and rounding modes other than round-to-nearest, ties-to-even. Only one canonical positive zero representation exists.

The bit layout is identical to IEEE 754: sign, exponent, and the significand with the MSb omitted. See `zkf.py` for the encoding rules.

# TODO

- _zkf_pack flushes underflow before rounding.

- Reduce divider quotient depth from WMAN+4 to WMAN+2. Current QFRAC=22 for WMAN=18, giving 11 radix-4 stages. For correct round-to-nearest with final remainder folded into sticky, WMAN + guard + round + sticky should need only WMAN+2 quotient fractional bits, rounded up to even for radix-4. That makes QFRAC=20, removing one radix-4 stage. It needs careful sticky handling when no produced tail bits remain -- zero-length tail ranges need generate-time handling.

## Semantics

Differences from IEEE 754: no NaN, no subnormals (exponent 0 always encodes +0, post-round underflow flushes to +0), no −0, no exceptions, overflow produces signed ±∞.

Infinity cases that would be NaN in IEEE 754:

| Expression          | Result                         |
|---------------------|--------------------------------|
| +∞ + −∞             | +0                             |
| 0 · ±∞              | +0                             |
| 0 ÷ 0               | +0                             |
| ±∞ ÷ ±∞             | +0                             |

Non-NaN infinity cases (same intent as IEEE 754):

| Expression          | Result                         |
|---------------------|--------------------------------|
| finite ÷ 0          | ±∞  (sign = sign of dividend)  |
| ±∞ ÷ 0              | ±∞  (sign = sign of dividend)  |
| finite ÷ ±∞         | +0                             |
| ±∞ · ±∞             | ±∞  (sign = signs XOR)         |
| finite≠0 · ±∞       | ±∞  (sign = signs XOR)         |

## Usage

The `zkf_*` modules implement various operators. Unless specified otherwise, all modules are zero-bubble throughput-1 pipelines, and all have fully registered inputs and outputs, allowing direct connection to BRAM, which is useful in register files etc. The two parameters are WEXP and WMAN setting the bit width of the biased exponent and the significand; the most significant bit of the significand is not stored, but there is a sign bit, so the total bit width is simply WFULL=WEXP+WMAN.

There are private helper modules named `_zkf_*`; they are not supposed to be instantiated by the user but the public modules depend on them. They do not offer any of the guarantees that are valid for the public modules.

The latency is documented in the doc comments separately for each module.

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
