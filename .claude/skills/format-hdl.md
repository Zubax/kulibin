# Format HDL

Format all `.v` files in the specified directory (or the current working directory) for semantic-aware column alignment, respecting a 120-character line limit.

## Steps

1. Read every `.v` file in the target directory.
2. Apply the alignment rules below to each file, making whitespace-only changes.
3. Verify no line exceeds 120 characters (`awk '{if(length>120)print NR": "length" - "$0}' file.v`).
4. If any line is over 120 characters, reduce spacing on that line and adjust nearby lines so the group still looks consistent.

## Alignment rules

### General philosophy

- Align semantically related declarations so that nearby names, buses, keywords, operators, and other distinctive elements form vertical columns.
- Use the minimum spacing that achieves alignment — no gratuitous padding.
- When perfect alignment would push a line past 120 characters, reduce spacing on the offending line and, if it would look out of place, reduce spacing on the rest of the group too so no single line stands out.
- When uncertain, use your best judgement to achieve aesthetically adequate results.

The only hard rule is that the source text should look good.

### Examples

```verilog
localparam          [WEXP-1:0] EXP_BIAS        = {1'b0, {WEXP-1{1'b1}}};
localparam          [WEXP-1:0] EXP_INF         = {WEXP{1'b1}};
localparam signed [WSCALE-1:0] WFRAC_EXT       =  WFRAC;
localparam signed [WSCALE-1:0] FORCE_INF_SCALE = {1'b0, {WSCALE-1{1'b1}}};
localparam          [WLOG-1:0] PRODUCT_LOG2_HI =  WMAG - 1;
localparam          [WLOG-1:0] PRODUCT_LOG2_LO =  WMAG - 2;

localparam [WEXP-1:0] EXP_BIAS       = {1'b0, {WEXP-1{1'b1}}};
localparam [WEXP-1:0] EXP_INF        = {WEXP{1'b1}};
localparam [WEXP-1:0] EXP_MAX_FINITE = EXP_INF - {{(WEXP-1){1'b0}}, 1'b1};
```

```verilog
input wire clk,
input wire in_valid,

input wire          [WMAG-1:0] mag,
input wire          [WLOG-1:0] mag_flog2,
input wire signed [WSCALE-1:0] scale,

output reg                 out_valid,
output reg [WEXP+WMAN-1:0] y
```

```verilog
input  wire                 clk,
input  wire                 in_valid,
input  wire [WEXP+WMAN-1:0] a,
output wire                 out_valid,
output wire [WEXP+WMAN-1:0] y
```

```verilog
wire signed [WEXP_WORK-1:0] bias_ext           = {{(WEXP_WORK-WEXP){1'b0}}, EXP_BIAS};
wire signed [WEXP_WORK-1:0] exp_max_finite_ext = {{(WEXP_WORK-WEXP){1'b0}}, EXP_MAX_FINITE};
wire signed [WEXP_WORK-1:0] s1_exp_biased_ext  = s1_exp_unbiased + bias_ext;

wire            s2_round_increment     = s2_guard && …;
wire [WMAN:0]   s2_rounded_ext         = {1'b0, s2_significand} + …;
wire            s2_round_carry         = s2_rounded_ext[WMAN];
wire [WMAN-1:0] s2_rounded_significand = s2_round_carry ? … : …;
wire [WEXP-1:0] s2_exp_rounded         = s2_exp_biased + …;
```

The last line is too long, break alignment locally to fit into 120 chars:

```verilog
wire [WFULL-1:0] s2_zero_y     = {WFULL{1'b0}};
wire [WFULL-1:0] s2_infinity_y = {s2_sign, EXP_INF, {WFRAC{1'b0}}};
wire [WFULL-1:0] s2_normal_y   = {s2_sign, s2_exp_rounded, s2_rounded_significand[WFRAC-1:0]};
wire [WFULL-1:0] s2_y = s2_result_zero ? s2_zero_y : (s2_result_infinity ? s2_infinity_y : s2_normal_y);
```

```verilog
reg                       s2_valid;
reg                       s2_sign;
(* keep *) reg [WMAG-1:0] s2_mag;
reg signed   [WSCALE-1:0] s2_scale;
reg                       s2_force_zero;
reg                       s2_force_inf;
```

Prefer keeping parameters on one line if it fits within 120 chars:

```verilog
_zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WMAG(WMAG), .WSCALE(WSCALE), .WLOG(WLOG)) u_pack (

// Only split when the parameter list alone exceeds 120 chars
_zkf_pack #(
    .WEXP(WEXP),
    …
) u_pack (
```

## Verification checklist

After formatting:

- [ ] Run `awk '{if(length>120)print NR": "length}' *.v` — no output expected.
- [ ] Confirm no extra blank lines or non-whitespace changes were introduced.
