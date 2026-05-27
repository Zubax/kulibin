# Zubax Kuibin floating point

A small and FPGA-friendly floating point format that is similar to IEEE 754 but intentionally omits support for NaN,
subnormals, exceptions, and rounding modes other than round-to-nearest, ties-to-even.
Only one canonical positive zero representation exists.

The bit layout is identical to IEEE 754: sign, exponent, and the significand with the MSb omitted.
See `zkf.py` for the encoding rules and range/precision limits.

See how ZKF beats other floating-point libraries in <https://zubax.github.io/fpga-floating-point-eval>.

## Semantics

Differences from IEEE 754: no NaN, no subnormals (exponent 0 always encodes +0; finite magnitudes in `(0, min_normal/2)`
round to +0; magnitudes in `[min_normal/2, min_normal)` round to signed min_normal), no −0, no exceptions,
overflow produces ±∞.

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

The subnormal round-to-nearest behavior is illustrated below, compared against the basic flush to zero for any value
below the min normal. The timing/area cost of both approaches is approximately equivalent while the rounding method
halves the worst-case error.

<img src="zkf_underflow_rounding.svg">

## Usage

The `zkf_*` modules located under `hdl/` implement various operators.
Unless specified otherwise, all modules are zero-bubble throughput-1 pipelines.
The two main parameters are WEXP and WMAN setting the bit width of the biased exponent and the significand;
the most significant bit of the significand is not stored, but there is a sign bit,
so the total bit width is simply WFULL=WEXP+WMAN.

The modules are entirely self-contained -- no external dependencies; simply drag-and-drop the directory into your project.
There are private helper modules named `_zkf_*`;
they are not supposed to be instantiated by the user but the public modules depend on them.
They do not offer any of the guarantees that are valid for the public modules.

Most modules provide pipelining knobs, like output register selection, internal registers, etc,
to enable tuning for the target chip. Common options seen in most modules are:
`STAGE_INPUT` -- latch inputs (no combinational paths at the input);
`STAGE_OUTPUT` -- registered outputs (no combinational paths at the output);
others control various computation stages.

Some of the simple combinational modules may produce non-canonical outputs; this does not affect compatibility with
other modules since they always canonicalize inputs, but it is worth noting.

| Module                | Function                                                       | Remarks                     |
|-----------------------|----------------------------------------------------------------|-----------------------------|
| `zkf_abs`             | Absolute value.                                                |                             |
| `zkf_neg`             | Negation.                                                      | May produce -0 (non-canon.) |
| `zkf_is_finite`       | True iff `x` is finite.                                        |                             |
| `zkf_saturate`        | Replace ±∞ with the nearest finite of the same sign.           | Does not canonicalize       |
| `zkf_cmp`             | Compare two values.                                            |                             |
| `zkf_sort`            | Min and max of two values.                                     |                             |
| `zkf_add`             | `a + b`.                                                       |                             |
| `zkf_addsub`          | `a + b` or `a − b` selected by `op_sub` (trivial wrapper).     |                             |
| `zkf_mul`             | `a × b`.                                                       |                             |
| `zkf_mul_ilog2_const` | `a × 2^K` for a elaboration-time signed integer `K`.           |                             |
| `zkf_div`             | `a ÷ b`; flags divide-by-zero.                                 |                             |
| `zkf_fma`             | `(a × b) + c` fused multiply-add, high precision, rounded once.| Larger than separate mul->add; non-finite handling follows mul->add.|
| `zkf_from_int`        | Cast signed two's-complement integer to float.                 |                             |
| `zkf_to_int`          | Cast float to signed two's-complement integer with saturation. |                             |
| `zkf_resize`          | Cast between different float formats.                          |                             |

## Notable sizes

### WMAN=18

An FPGA-friendly format because modern DSP-enabled FPGAs often implement 18x18 bit multipliers, which means that a
narrower mantissa is unlikely to save much resources or nontrivially improve timings as long as hardware multipliers
are used.

One can stay within 24 bits total by choosing WEXP=6:

    WEXP=6 WMAN=18 WFRAC=17 WFULL=24 BIAS=31
    lowest     = 1/1073741824 ≈ 9.313e-10
    max        = 0xFFFF_C000  ≈ 4.295e+09
    ε          = 1/131072     ≈ 7.629e-06

### WMAN=36

Similar to the above, WMAN=36 is efficient on common FPGAs because it maps multiplication to four 18x18 DSP slices.
This is often a better fit for intermediate result representation to avoid error accumulation --
the precision lands halfway between IEEE 754 binary64 and binary32.

Usually, on an 18x18 DSP chip, going even a single bit higher causes f_max to tank dramatically while area explodes.
Thus this is likely to be the optimal choice for a large number of applications.

Using binary32-compatible exponent WEXP=8, 44 bits total:

    WEXP=8 WMAN=36 WFRAC=35 WFULL=44 BIAS=127
    lowest     = 1/85070591730234615865843651857942052864 ≈ 1.175e-38
    max        = 0xFFFFFFFF_F0000000_00000000_00000000    ≈ 3.403e+38
    ε          = 1/34359738368                            ≈ 2.910e-11

### IEEE 754-like

ZKF offers limited compatibility with IEEE 754 so while it can match the bit layout,
not all states are mappable between the formats.

- WEXP=5  WMAN=11: IEEE 754 binary16-like
- WEXP=8  WMAN=24: IEEE 754 binary32-like
- WEXP=11 WMAN=53: IEEE 754 binary64-like
