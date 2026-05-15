# Simple Signed Floating-Point Format Spec

Zubax Kulibin simple float format spec.

## 1. Purpose

Implement a small, deterministic, FPGA-friendly floating-point format with:

```text
no NaN
no subnormals
no exception flags
one rounding mode only: round-to-nearest, ties-to-even
post-round underflow-to-zero
overflow-to-signed-infinity
canonical positive zero
canonical signed infinities
```

The design goal is **simplicity, verifiability, and predictable FPGA cost**, not IEEE-754 compatibility.

---

## 2. Parameters and Encoding

Use two main parameters:

```verilog
WEXP >= 2          // exponent field width
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

Encoding rule follows IEEE 754 where it makes sense:

```text
exponent == 0:
    value = +0
    sign and fraction are ignored on input
    output must always be canonical {sign=0, exponent=0, fraction=0}

exponent all ones:
    value = (-1)^sign * infinity
    fraction is ignored on input
    output must always be canonical {sign, exponent=all_ones, fraction=0}

otherwise:
    value = (-1)^sign * (1.fraction) * 2^(exponent - BIAS)
```

Canonical infinity and zero have zero fraction bits. Only canonical representations can be produced.
Normal finite numbers use biased exponent values from 1 to `2^WEXP - 2`, inclusive.

Maximum finite value:

```text
MAX = (2 - 2^(-WFRAC)) * 2^((2^WEXP - 2) - BIAS)
```

Minimum normal value:

```text
MIN_NORMAL = 2^(1 - BIAS)
```

---

## 3. Global Arithmetic Semantics

Every operation is defined as:

```text
1. Decode inputs to exact mathematical values, including ±infinity.
2. Compute the exact result using the operation-specific rules below.
3. Pack the result using the rules below.
```

Packing rule:

```text
if exact result is +infinity or -infinity:
    return canonical signed infinity

if exact finite result is zero:
    return canonical +0

normalize:
    abs(result) = m * 2^e, where 1 <= m < 2

round m to WMAN bits using round-to-nearest, ties-to-even

if rounding overflows significand:
    shift right by 1
    increment exponent

if rounded exponent is below the minimum normal exponent:
    return canonical +0       // post-round flush-to-zero; subnormals are not encoded

if exponent overflows into the all-ones exponent code:
    return canonical signed infinity

otherwise:
    return packed normal number
```

Underflow is determined after rounding. Therefore, a finite exact result with magnitude below `MIN_NORMAL` may still
produce `MIN_NORMAL` if round-to-nearest ties-to-even promotes it into the normal range.

Rounding uses normal guard/round/sticky logic:

```text
increment retained significand iff:
    guard == 1 and (round == 1 or sticky == 1 or retained_lsb == 1)
```

There are no rounding-mode inputs and no exception/status outputs.

Infinity arithmetic is deterministic and deliberately does not produce NaN:

```text
finite + infinity, or infinity + finite:
    return that infinity

infinity + infinity with same sign:
    return that infinity

infinity + infinity with opposite signs:
    return canonical +0

finite nonzero * infinity, or infinity * finite nonzero:
    return signed infinity with sign = sign(a) XOR sign(b)

zero * infinity:
    return canonical +0

infinity * infinity:
    return signed infinity with sign = sign(a) XOR sign(b)

finite nonzero / zero, or infinity / zero:
    return signed infinity with sign = sign(a)

zero / zero:
    return canonical +0

finite / infinity:
    return canonical +0

infinity / finite nonzero:
    return signed infinity with sign = sign(a) XOR sign(b)

infinity / infinity:
    return canonical +0
```

Subtraction is defined as addition with the sign of the second operand inverted.

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

All outputs must be canonical. Any input with `exponent == 0` must be treated as zero, and any input with
`exponent == all_ones` must be treated as signed infinity. The fraction field is ignored for both special input
classes.

## 4.1. Reset Strategy

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

---

# Required Modules

Results of all public (end-user) modules must be registered.

Arbitrary hardcoded widths are not allowed; all width parameters must be ultimately derived from WEXP and WMAN.

Modules are prefixed with `zkf_` meaning "Zubax Kulibin float".
Internal helper modules are underscore-prefixed like `_zkf_`.

## 5. Add/Subtract

The core function is `zkf_add`:

```verilog
zkf_add #(parameter int WEXP = 6, parameter int WMAN = 18)(
    input wire clk,
    input wire rst,

    input wire             in_valid,
    input wire [WFULL-1:0] a,
    input wire [WFULL-1:0] b,

    output wire             out_valid,
    output wire [WFULL-1:0] y
);
```

Based on that, a dual-purpose add/sub module can be defined that instantiates only a single adder (which is large)
and computes a-b as a+(-b) by xoring the b sign with `op_sub`:

```verilog
zkf_addsub #(parameter int WEXP = 6, parameter int WMAN = 18)(
    input  wire clk,
    input  wire rst,

    input  wire             in_valid,
    input  wire [WFULL-1:0] a,
    input  wire [WFULL-1:0] b,
    input  wire             op_sub, // 0: y=a+b; 1: y=a-b

    output wire             out_valid,
    output wire [WFULL-1:0] y
);
```

---

## 6. Multiplier

Streaming, no stalling.

```verilog
zkf_mul #(parameter int WEXP = 6, parameter int WMAN = 18) (
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
flush underflow to zero after rounding
map overflow to signed infinity
```

---

## 7. Divider

Quotient-only divider, streamed, zero-bubble:

```verilog
zkf_div #(parameter int WEXP = 6, parameter int WMAN = 18)(
    input  wire clk,
    input  wire rst,

    input  wire             in_valid,
    input  wire [WFULL-1:0] a,
    input  wire [WFULL-1:0] b,

    output wire             out_valid,
    output wire [WFULL-1:0] q,
    output wire             div0
);
```

Semantics:

```text
if a == 0:
    q = +0

else if b == 0:
    q = signed infinity with sign = sign(a)

else:
    q = pack(a / b)
```

This is equivalent to IEEE 754 division for finite operands and infinities except that NaN is not representable:
undefined IEEE cases such as `0 / 0` and `infinity / infinity` return canonical `+0` instead.

The `div0` output is asserted when `b` decodes as zero.

Implementation guidance:

```text
Use a radix-4 SRT or equivalent.
Generate at least WMAN + guard/round/sticky quotient precision.
Use the final partial remainder to decide round-to-nearest ties-to-even.
```

Performance target: at least two quotient bits per cycle.

---

## 8. Divider With Residual Remainder

Combined quotient/residual divider, streamed, zero-bubble:

```verilog
zkf_divrem #(parameter int WEXP = 6, parameter int WMAN = 18)(
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

The `q` and `div0` outputs are bit-for-bit identical to `zkf_div` with the same parameters and inputs.

Residual semantics:

```text
This is a division residual, not C fmod and not IEEE remainder.

if a == 0:
    r = +0

else if b == 0:
    r = +0

else if q is infinity:
    r = +0

else:
    r = pack(a - b * q)
```

The residual expression above uses the decoded, rounded value of output `q` and is evaluated using the same
deterministic no-NaN infinity arithmetic as the rest of this format. Notable consequences:

```text
finite / infinity:
    q = +0
    r = canonicalized a

infinity / infinity:
    q = +0
    r = signed infinity with sign = sign(a)

infinity / finite nonzero:
    q = signed infinity with sign = sign(a) XOR sign(b)
    r = +0
```

Implementation guidance:

```text
Share the quotient generation path with zkf_div.
Use the final partial remainder instead of directly evaluating a - b * q with a separate multiplier.
After quotient rounding, adjust the residual if the quotient was incremented.
Pack the residual alongside the quotient so both outputs are aligned under out_valid.
```

Reusable logic shared by `zkf_div` and `zkf_divrem` should be extracted into nonpublic, underscore-prefixed helper
modules, consistent with the internal helper module convention above.

---

## 9. Cast From Signed Integer

```verilog
zkf_from_sint #(
    parameter int WEXP = 6,
    parameter int WMAN = 18,
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
map exponent overflow to signed infinity
zero input maps to canonical +0
```

---

## 10. Cast To Signed Integer

```verilog
zkf_to_sint #(
    parameter int WEXP = 6,
    parameter int WMAN = 18,
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
if a == +infinity:
    y = 2^(WINT-1)-1

else if a == -infinity:
    y = -2^(WINT-1)

else:
    y = signed integer round_nearest_ties_even(a)
```

Overflow saturates to the signed two’s-complement integer range:

```text
negative overflow -> -2^(WINT-1)
positive overflow ->  2^(WINT-1)-1
```

Zero maps to integer zero.

---

## 11. Cast Between Two Format Sizes

```verilog
zkf_resize #(
    parameter int WEXP_IN  = 6,
    parameter int WMAN_IN  = 18,
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
input exponent all ones is signed infinity
output zero must be canonical
output infinity must be canonical
narrowing rounds to nearest ties-to-even
widening is exact unless exponent range changes
target underflow flushes to zero after rounding
target overflow maps to signed infinity
```

---

## 12. Sqrt/log2/exp2

These may be FSM-based instead of streaming, which would necessitate in_ready/out_ready; this remains to be seen.

```verilog
/// sqrt(+0)       = +0
/// sqrt(finite>0) = correctly rounded sqrt(x)
/// sqrt(+inf)     = +inf
/// sqrt(x<0)      = -inf, domain_error=1
module zkf_sqrt #(parameter WEXP = 6, parameter WMAN = 18) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] x,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y,
    output wire                 domain_error
);

/// log2(finite>0) = log2(x)
/// log2(+inf)     = +inf
/// log2(+0)       = -inf, pole=1
/// log2(x<0)      = -inf, domain_error=1
module zkf_log2 #(parameter WEXP = 6, parameter WMAN = 18) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] x,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y,
    output wire                 domain_error,
    output wire                 pole
);

/// exp2(-inf)       = +0
/// exp2(finite)     = 2^x
/// exp2(+inf)       = +inf
/// post-round underflow = +0
/// overflow             = +inf
module zkf_exp2 #(parameter WEXP = 6, parameter WMAN = 18) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] x,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y
);
```

---

## Combinational helpers

These circuits are very simple and as such usually do not warrant a separate pipeline stage.
They may be implemented as functions inside a parameterized module, or macros; better ideas welcome.
Infinities of the same sign compare equal.

- `zkf_is_finite(x) -> bool` -- true if x is finite
- `zkf_saturate(x) -> X` -- if x is finite, returns it as-is; if infinite, returns the nearest representable finite.
- `zkf_abs(x) -> X` -- zero the sign bit.
- `zkf_neg(x) -> X` -- flip the sign bit.

Comparison/sorting is cheap as it can be done using WFULL-wide integer arithmetic.

```verilog
zkf_cmp #(parameter WEXP = 6, parameter WMAN = 18) (
    input wire [WFULL-1:0] a,
    input wire [WFULL-1:0] b,

    output reg a_gt_b, // a > b
    output reg a_eq_b, // a = b
    output reg a_lt_b  // a < b
);
```

```verilog
zkf_sort #(parameter WEXP = 6, parameter WMAN = 18) (
    input wire [WFULL-1:0] a,
    input wire [WFULL-1:0] b,

    output reg min, // min(a,b)
    output reg max  // max(a,b)
);
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
no NaN encodings exist
infinity encodings exist and outputs are canonical
exponent==0 always decodes as zero
exponent==all_ones always decodes as signed infinity
zero output is always {0,0,0}
floating-point overflow always produces signed infinity
rounded underflow always produces +0
rounding is ties-to-even
undefined infinity cases produce +0
division by zero asserts div0
add/sub module implements both operations exactly per spec
mul uses the same pack semantics as add/sub
div quotient matches exact a/b rounded per spec
div residual matches the documented a - b*q rule rounded per spec
resize equals decode-then-pack into target format
```

This format deliberately avoids most IEEE-754 corner cases. The only special values are canonical zero and canonical
signed infinities.

The verification suite must run against Icarus Verilog and Verilator. Full state space exploration with verification is
required for small exponent/mantissa configurations; target approx. WEXP=3 and WMAN=4. Larger sizes to be tested with
random test vectors. Explicit manual tests covering all edge cases and representative normal behaviors are required,
including special input canonicalization, infinity propagation, undefined infinity cases, overflow to infinity, resize
with infinity, casts with infinity, and division by zero.

Yosys/nextpnr-based synthesizability tests with full optimization and retiming enabled are required for an ECP5-like
target, speed grade 6. FULL OPTIMIZATION AND RETIMING ARE MANDATORY, otherwise the results will not be meaningful. A
pretty human-friendly colorful HTML report with tables must be composed by the synthesis test runner showing at least
the maximum clock frequency, worst slack paths, and LUT usage for each module using exp=6 bits, significand=18 bits
(for a total of 24 bits) for reference. There must be a separate synthesizer run / synthesis target per module such that
we could evaluate each one independently, including the internal helper modules (the ones named with the underscore),
except for the purely combinational ones.
