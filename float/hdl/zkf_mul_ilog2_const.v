/// Constant-power-of-two multiplier: y = a * 2^K, where K is a compile-time signed integer parameter.
/// Register stages: 1.
///
/// This is far cheaper than full multiplication (zkf_mul) or division (zkf_div) because the mantissa is preserved
/// bit-for-bit and only the biased exponent is incremented by K. Special inputs (zero, signed infinity) are
/// canonicalized at the output. No rounding is required: the operation is exact in the format's normal range.
///
/// Elaboration fails when K is so extreme that every normal input either overflows to signed infinity or underflows
/// to zero, since the module is then provably useless. Concretely, K must satisfy -EXP_MAX_FINITE < K < EXP_MAX_FINITE
/// where EXP_MAX_FINITE = 2**WEXP-2. This bound preserves at least one exponent value that maps to a normal output.

`default_nettype none

module zkf_mul_ilog2_const #(
    parameter         WEXP = 6,    // exponent field width
    parameter         WMAN = 18,   // significand precision including the hidden bit
    parameter integer K    = 0     // signed integer exponent shift: y = a * 2^K
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,

    output reg                 out_valid,
    output reg [WEXP+WMAN-1:0] y           // y = a * 2^K, where -(2**WEXP-2) < K < (2**WEXP-2)
);
    localparam WFRAC    = WMAN - 1;
    localparam WFULL    = WEXP + WMAN;
    localparam WEXP_EXT = WEXP + 2;     // signed accumulator wide enough for a_exp + K at any allowed K

    localparam [WEXP-1:0] EXP_INF = {WEXP{1'b1}};

    // Signed integer bounds for the always-overflow / always-underflow guards. Using `integer` keeps both the
    // positive and negative limits in 32-bit signed arithmetic so that the elaboration-time comparisons against K
    // are unambiguous across Verilog tools.
    localparam integer K_LIMIT_OVERFLOW  =   (1 << WEXP) - 2;
    localparam integer K_LIMIT_UNDERFLOW = -((1 << WEXP) - 2);

    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wm
            _zkf_invalid_wexp_or_wman u_invalid();
        end
        // K is an integer parameter, and the K bound checks below use 32-bit integer arithmetic.
        if (WEXP > 31) begin : g_invalid_wexp_too_wide
            _zkf_invalid_mul_ilog2_const_wexp_too_wide_unportable u_invalid();
        end
        // K = EXP_MAX_FINITE forces every normal input to overflow (new_biased_exp >= EXP_INF for old_biased_exp >= 1).
        if (K >= K_LIMIT_OVERFLOW) begin : g_invalid_k_always_overflow
            _zkf_invalid_mul_ilog2_const_k_always_overflow u_invalid();
        end
        // K = -EXP_MAX_FINITE forces underflow (new_biased_exp <= 0 for old_biased_exp <= EXP_MAX_FINITE).
        if (K <= K_LIMIT_UNDERFLOW) begin : g_invalid_k_always_underflow
            _zkf_invalid_mul_ilog2_const_k_always_underflow u_invalid();
        end
    endgenerate
    // verilator coverage_on

    // Decode and classify.
    wire             a_sign = a[WFULL-1];
    wire [WEXP-1:0]  a_exp  = a[WFULL-2:WFRAC];
    wire [WFRAC-1:0] a_frac = a[WFRAC-1:0];
    wire             a_zero = ~|a_exp;
    wire             a_inf  =  &a_exp;

    // The biased exponent of the result is a_exp + K. Two boolean conditions on it drive the output mux:
    //   overflow  = (a_exp + K) > EXP_MAX_FINITE   iff   (a_exp + K - EXP_MAX_FINITE - 1) >= 0
    //   underflow = (a_exp + K) < 1                iff   (a_exp + K - 1)                  <  0
    // Both right-hand sides are signed expressions whose sign bit decides the flag. Folding K with its constant
    // companion into a single offset removes the chained add-then-compare carry path the synthesiser would otherwise
    // place on the critical path.
    //
    // Several nets below are wrapped with `// verilator coverage_off`. Per-instance toggle coverage on this module
    // is intrinsically incomplete: each parameter specialization (one per distinct K) holds these signals at a
    // constant or single-direction value -- the of_acc / uf_acc offsets are pinned by K, underflow is identically
    // zero whenever K >= 0, overflow is identically zero whenever K <= 0, and the EXP_INF / zero-fraction slots of
    // y_inf_w never see both polarities in a single instance. Across the wrap's seven K instances the full range is
    // exercised, but verilator scores toggle per instance, so the suppressions silence the unattainable transitions.

    // Folded constants. K - EXP_MAX_FINITE - 1 for overflow, K - 1 for underflow.
    localparam signed [WEXP_EXT-1:0] K_OF_OFFSET = K - ((1 << WEXP) - 2) - 1;
    localparam signed [WEXP_EXT-1:0] K_UF_OFFSET = K - 1;

    // Two parallel signed adds. The sign bit of each result encodes the flag directly.
    // verilator coverage_off
    wire signed [WEXP_EXT-1:0] of_acc    = $signed({{(WEXP_EXT-WEXP){1'b0}}, a_exp}) + K_OF_OFFSET;
    wire signed [WEXP_EXT-1:0] uf_acc    = $signed({{(WEXP_EXT-WEXP){1'b0}}, a_exp}) + K_UF_OFFSET;
    wire                       overflow  = ~of_acc[WEXP_EXT-1];
    wire                       underflow =  uf_acc[WEXP_EXT-1];
    // verilator coverage_on
    wire result_is_zero = a_zero || underflow;
    wire result_is_inf  = a_inf  || overflow;

    // Normal-output exponent: low WEXP bits of (a_exp + K). The truncating add wraps, which is fine because the
    // normal-output mux is suppressed whenever result_is_zero or result_is_inf is asserted.
    wire [WEXP-1:0] new_exp = a_exp + K[WEXP-1:0];

    // Output candidate forms. Canonicalisation is implicit: zero has sign/frac cleared, infinity has frac cleared.
    // verilator coverage_off
    wire [WFULL-1:0] y_inf_w    = {a_sign, EXP_INF, {WFRAC{1'b0}}};
    // verilator coverage_on
    wire [WFULL-1:0] y_normal_w = {a_sign, new_exp, a_frac};

    // Reset only stream validity. Payload register intentionally free-runs (project Reset strategy).
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid;
        end
        // result_is_zero takes priority over result_is_inf. For valid K the two flags are mutually exclusive,
        // but the 2'b11 row is listed so the priority is explicit and the case is full.
        case ({result_is_zero, result_is_inf})
            2'b10, 2'b11: y <= {WFULL{1'b0}};
            2'b01:        y <= y_inf_w;
            default:      y <= y_normal_w;
        endcase
    end
endmodule

`default_nettype wire
