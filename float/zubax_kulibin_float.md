# Simple Signed Floating-Point Format Spec

Zubax Kulibin simple float format spec.

## 1. Purpose

Implement a small, deterministic, FPGA-friendly floating-point format with:

```text
no NaN
no infinity
no subnormals
no exception flags
one rounding mode only: round-to-nearest, ties-to-even
underflow-to-zero
overflow-to-signed-saturation
canonical positive zero
```

The design goal is **simplicity, verifiability, and predictable FPGA cost**, not IEEE-754 compatibility.

---

## 2. Parameters and Encoding

Use two main parameters:

```verilog
WEXP >= 3          // exponent field width
WMAN >= 4          // total significand precision, including hidden leading 1
```

Stored fraction width:

```verilog
WFRAC = WMAN - 1
WFULL = 1 + WEXP + WFRAC
```

Packed format:

```text
sign | exponent | fraction
```

Bit layout:

```text
[WFULL-1]                 sign
[WFULL-2 : WFRAC]        unsigned exponent
[WFRAC-1 : 0]            fraction
```

Bias:

```text
BIAS = 2^(WEXP - 1) - 1
```

Encoding rule:

```text
exponent == 0:
    value = +0
    sign and fraction are ignored on input
    output must always be canonical {sign=0, exponent=0, fraction=0}

exponent != 0:
    value = (-1)^sign * (1.fraction) * 2^(exponent - BIAS)
```

The all-ones exponent is **not special**. It is the largest finite exponent.

Maximum finite value:

```text
MAX = (2 - 2^(-WFRAC)) * 2^((2^WEXP - 1) - BIAS)
```

Minimum normal value:

```text
MIN_NORMAL = 2^(1 - BIAS)
```

Signed saturation values:

```text
+SAT = {0, all_ones_exp, all_ones_frac}
-SAT = {1, all_ones_exp, all_ones_frac}
```

---

## 3. Global Arithmetic Semantics

Every operation is defined as:

```text
1. Decode inputs to exact mathematical real values.
2. Compute the exact real result.
3. Pack the result using the rules below.
```

Packing rule:

```text
if exact result is zero:
    return canonical +0

if abs(result) < MIN_NORMAL:
    return canonical +0       // flush-to-zero, no subnormal rounding

normalize:
    abs(result) = m * 2^e, where 1 <= m < 2

round m to WMAN bits using round-to-nearest, ties-to-even

if rounding overflows significand:
    shift right by 1
    increment exponent

if exponent overflows:
    return signed saturation

otherwise:
    return packed normal number
```

Rounding uses normal guard/round/sticky logic:

```text
increment retained significand iff:
    guard == 1 and (round == 1 or sticky == 1 or retained_lsb == 1)
```

There are no rounding-mode inputs and no exception/status outputs.

---

## 4. Common Module Interface

Variable-latency pipelines are acceptable if simplifies the design.
All modules are streamed zero-bubble without backpressure.

```verilog
input  wire clk;
input  wire rst;        // synchronous active-high reset
input  wire in_valid;
output wire out_valid;
```

All outputs must be canonical. Any input with `exponent == 0` must be treated as zero.

---

# Required Modules

Arguments and results of all public (end-user) modules must be registered because the results may be fed by long
combinational circuits or be assigned from memory. This requirement does not apply to internal helper modules.

Arbitrary hardcoded widths are not allowed; all width parameters must be ultimately derived from WEXP/WMAN.

Modules are prefixed with `zkf_` meaning "Zubax Kulibin float".
Internal helper modules are underscore-prefixed like `_zkf_`.

## 5. Add/Subtract

```verilog
zkf_addsub #(parameter int WEXP = 8, parameter int WMAN = 16)(
    input  wire clk,
    input  wire rst,

    input  wire             in_valid,
    input  wire [WFULL-1:0] a,
    input  wire [WFULL-1:0] b,
    input  wire             op_sub,     // 0: a+b, 1: a-b

    output wire             out_valid,
    output wire [WFULL-1:0] y
);

zkf_sub // similar...
```

Implementation guidance (rough):

```text
stage 1: unpack, zero detection, exponent compare
stage 2: align smaller significand using sticky bit
stage 3: signed add/subtract
stage 4: normalize
stage 5: round, saturate/flush, pack
```

A 3–6 stage pipeline is acceptable.

---

## 6. Multiplier

Streaming, no stalling.

```verilog
zkf_mul #(parameter int WEXP = 8, parameter int WMAN = 16) (
    input  wire clk,
    input  wire rst,

    input  wire             in_valid,
    input  wire [WFULL-1:0] a,
    input  wire [WFULL-1:0] b,

    output wire             out_valid,
    output wire [WFULL-1:0] y
);
```

Implementation guidance:

```text
sign = sign_a XOR sign_b
exponent = exponent_a + exponent_b - BIAS
significands are unsigned WMAN-bit values with hidden leading 1
multiply significands using FPGA DSP blocks, provide 2 dummy retiming stages after multiplication
normalize product
round-to-nearest ties-to-even
flush underflow to zero
saturate overflow
```

A 4-7 stage pipeline is acceptable.

---

## 7. Divider With Residual Remainder

Combined quotient/residual module, streamed, zero-bubble:

```verilog
zkf_divrem #(parameter int WEXP = 8, parameter int WMAN = 16)(
    input  wire clk,
    input  wire rst,

    input  wire             in_valid,
    input  wire [WFULL-1:0] a,
    input  wire [WFULL-1:0] b,

    output wire             out_valid,
    output wire [WFULL-1:0] q,
    output wire [WFULL-1:0] r,
    output wire             div0
);
```

Quotient semantics:

```text
if a == 0:
    q = +0

else if b == 0:
    q = signed saturation with sign = sign(a)

else:
    q = pack(a / b)
```

Residual remainder semantics:

```text
This is a division residual, not C fmod and not IEEE remainder.

if a == 0:
    r = +0

else if b == 0:
    r = +0

else if q saturated:
    r = +0

else:
    r = pack(a - b * q)
```

Implementation guidance:

```text
Use radix-4 SRT, radix-4 non-restoring, or equivalent.
Generate at least WMAN + guard/round/sticky quotient precision.
Use the final partial remainder to decide round-to-nearest ties-to-even.
After quotient rounding, adjust the residual if the quotient was incremented.
```

Performance target:

```text
roughly two quotient bits per cycle
latency about ceil((WMAN + extra_round_bits) / 2) + small constant
```

---

## 8. Cast From Signed Integer

```verilog
zkf_from_sint #(
    parameter int WEXP = 8,
    parameter int WMAN = 16,
    parameter int WINT = 32
) (
    input  wire clk,
    input  wire rst,

    input  wire                   in_valid,
    input  wire signed [WINT-1:0] a,

    output wire             out_valid,
    output wire [WFULL-1:0] y
);
```

Semantics:

```text
y = pack(real_value_of_signed_integer(a))
```

Implementation guidance:

```text
handle INT_MIN correctly using unsigned magnitude
find leading one
derive exponent
round discarded integer bits using ties-to-even
saturate if exponent too large
zero input maps to canonical +0
```

---

## 9. Cast To Signed Integer

```verilog
zkf_to_sint #(
    parameter int WEXP = 8,
    parameter int WMAN = 16,
    parameter int WINT = 32
) (
    input  wire clk,
    input  wire rst,

    input  wire             in_valid,
    input  wire [WFULL-1:0] a,

    output wire                   out_valid,
    output wire signed [WINT-1:0] y
);
```

Semantics:

```text
y = signed integer round_nearest_ties_even(a)
```

Overflow saturates to the signed two’s-complement integer range:

```text
negative overflow -> -2^(WINT-1)
positive overflow ->  2^(WINT-1)-1
```

Zero maps to integer zero.

---

## 10. Cast Between Two Format Sizes

```verilog
zkf_resize #(
    parameter int WEXP_IN  = 8,
    parameter int WMAN_IN  = 16,
    parameter int WEXP_OUT = 5,
    parameter int WMAN_OUT = 11
) (
    input  wire clk,
    input  wire rst,

    input  wire                in_valid,
    input  wire [IN_WFULL-1:0] a,

    output wire                 out_valid,
    output wire [OUT_WFULL-1:0] y
);
```

Semantics:

```text
y = pack_to_output_format(decode_input_format(a))
```

Rules:

```text
input exponent == 0 is zero
output zero must be canonical
narrowing rounds to nearest ties-to-even
widening is exact unless exponent range changes
target underflow flushes to zero
target overflow saturates
```

---

# Verification Requirements

Implement a small integer/rational reference model and test all modules against:

```text
decode -> exact operation -> pack
```

Required properties:

```text
all outputs canonical
no NaN/Inf encodings exist
exponent==0 always decodes as zero
zero output is always {0,0,0}
overflow always produces signed saturation
underflow always produces +0
rounding is ties-to-even
add/sub module implements both operations exactly per spec
mul uses the same pack semantics as add/sub
div quotient matches exact a/b rounded per spec
resize equals decode-then-pack into target format
```

This format deliberately avoids IEEE-754 corner cases. The only special value is canonical zero.

The verification suite must run against Icarus Verilog and Verilator. Full state space exploration with verification is required for small exponent/mantissa configurations; target approx. WEXP=3 and WMAN=4. Larger sizes to be tested with random test vectors. Explicit manual tests covering all edge cases and representative normal behaviors are required.

Yosys/nextpnr-based synthesizability tests with full optimization and retiming enabled are required for an ECP5-like target, speed grade 8. FULL OPTIMIZATION AND RETIMING ARE MANDATORY, otherwise the results will not be meaningful. A pretty human-friendly colorful HTML report with tables must be composed by the synthesis test runner showing at least the maximum clock frequency, worst slack paths, and LUT usage for each component using exp=7 bits, significand=17 bits (for a total of 24 bits) for reference.
