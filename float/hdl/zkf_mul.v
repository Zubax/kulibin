/// Streamed Zubax Kulibin float multiplier.
///
/// STAGE_INPUT=0: operands feed the multiplier combinationally (default).
/// STAGE_INPUT=1: latch the inputs before any combinational logic, isolating them from upstream paths (+1 cycle).
///
/// STAGE_PRODUCT=0: single-cycle multiplication. The DSP cascade (e.g. 4*MULT18X18D + 2*ALU54B for WMAN=36 on ECP5)
///   is one combinational hop into the s1_mag register. Usually this is the best option.
///
/// STAGE_PRODUCT>=1: split the product into a 2*2 grid of (ceil(WMAN/2)) wide partial products, register them,
///   then sum in the next cycle. Synthesis tools absorb the partial-product registers as DSP output registers and
///   the sum as the ALU54B-style cascade, splitting the chain across two clock periods. Costs one extra pipeline
///   cycle of latency. Values above 1 are treated as 1; further splits are reserved for future expansion.
///
/// STAGE_PACK=0: pack inputs are combinational (default).
/// STAGE_PACK=1: register pack inputs (forwarded to _zkf_pack.STAGE_INPUT) (+1 cycle).
///
/// STAGE_OUTPUT=0: the result is combinational (default).
/// STAGE_OUTPUT=1: the result is registered; good if the module feeds long external combinational paths (+1 cycle).

`default_nettype none

`define ZKF_MUL_LATENCY (1 + STAGE_INPUT + STAGE_PRODUCT + STAGE_PACK + STAGE_OUTPUT)

module zkf_mul #(
    parameter WEXP          = 6,    // exponent field width
    parameter WMAN          = 18,   // significand precision including the hidden bit
    parameter STAGE_INPUT   = 0,
    parameter STAGE_PRODUCT = 0,
    parameter STAGE_PACK    = 0,
    parameter STAGE_OUTPUT  = 0,
    parameter LATENCY       = `ZKF_MUL_LATENCY   // must equal the register-stage count; checked below
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y
);
    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wman
            _zkf_invalid_wexp_or_wman u_invalid();
        end
        if (LATENCY != `ZKF_MUL_LATENCY) begin : g_invalid_latency
            _zkf_invalid_latency_mismatch u_invalid();
        end
    endgenerate
    // verilator coverage_on

    localparam WFRAC         = WMAN - 1;
    localparam WFULL         = WEXP + WMAN;
    localparam WMAG          = 2 * WMAN;
    localparam WEXP_UNBIASED = WEXP + 2;

    localparam [WEXP-1:0] EXP_BIAS = {1'b0, {WEXP-1{1'b1}}};
    localparam [WEXP-1:0] EXP_INF  = {WEXP{1'b1}};

    localparam signed [WEXP_UNBIASED-1:0] ZERO_EXT = {WEXP_UNBIASED{1'b0}};
    localparam signed [WEXP_UNBIASED-1:0] ONE_EXT  = {{(WEXP_UNBIASED-1){1'b0}}, 1'b1};

    // Optional input register stage: latch the operands before any combinational logic (+1 cycle when STAGE_INPUT=1).
    wire             in_valid_q;
    wire [WFULL-1:0] a_q;
    wire [WFULL-1:0] b_q;
    zkf_pipe #(.W(2*WFULL), .N(STAGE_INPUT ? 1 : 0)) u_input_pipe (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in({b, a}),
        .out_valid(in_valid_q), .out({b_q, a_q})
    );

    // Operand decode/classification.
    wire             a_sign = a_q[WFULL-1];
    wire             b_sign = b_q[WFULL-1];
    wire [WEXP-1:0]  a_exp  = a_q[WFULL-2:WFRAC];
    wire [WEXP-1:0]  b_exp  = b_q[WFULL-2:WFRAC];
    wire [WFRAC-1:0] a_frac = a_q[WFRAC-1:0];
    wire [WFRAC-1:0] b_frac = b_q[WFRAC-1:0];

    wire            a_zero        = a_exp == {WEXP{1'b0}};
    wire            b_zero        = b_exp == {WEXP{1'b0}};
    wire            a_inf         = a_exp == EXP_INF;
    wire            b_inf         = b_exp == EXP_INF;
    wire            result_zero   = a_zero || b_zero;
    wire            result_inf    = !result_zero && (a_inf || b_inf);
    // verilator coverage_off
    // Structurally non-toggling: the reconstructed significands' MSB is the always-1 hidden bit (fraction
    // checked via the a/b ports), and the exponent extensions / bias are zero-extension padding of a
    // non-negative exponent (high bits constant 0) plus a compile-time-constant bias. exp_unbiased_in
    // below (the real exponent sum) stays covered.
    wire [WMAN-1:0] a_significand = {1'b1, a_frac};
    wire [WMAN-1:0] b_significand = {1'b1, b_frac};

    wire signed [WEXP_UNBIASED-1:0] a_exp_ext       = {{(WEXP_UNBIASED-WEXP){1'b0}}, a_exp};
    wire signed [WEXP_UNBIASED-1:0] b_exp_ext       = {{(WEXP_UNBIASED-WEXP){1'b0}}, b_exp};
    wire signed [WEXP_UNBIASED-1:0] bias_ext        = {{(WEXP_UNBIASED-WEXP){1'b0}}, EXP_BIAS};
    // verilator coverage_on
    wire signed [WEXP_UNBIASED-1:0] exp_unbiased_in = a_exp_ext + b_exp_ext - (bias_ext <<< 1);

    wire pre_sign       = a_sign ^ b_sign;
    wire pre_force_zero = result_zero;
    wire pre_force_inf  = result_inf;

    // -- Magnitude source. STAGE_PRODUCT=0 drives the combinational a*b straight into the s1 capture;
    // STAGE_PRODUCT>=1 registers a 2*2 grid of partial products and combines them in the next cycle.
    wire                            mag_src_valid;
    wire                            mag_src_sign;
    wire signed [WEXP_UNBIASED-1:0] mag_src_exp_base;
    wire                            mag_src_force_zero;
    wire                            mag_src_force_inf;
    wire                 [WMAG-1:0] mag_src;

    generate
        if (STAGE_PRODUCT == 0) begin : g_mul_unsplit
            assign mag_src            = a_significand * b_significand;
            assign mag_src_valid      = in_valid_q;
            assign mag_src_sign       = pre_sign;
            assign mag_src_exp_base   = exp_unbiased_in;
            assign mag_src_force_zero = pre_force_zero;
            assign mag_src_force_inf  = pre_force_inf;
        end else begin : g_mul_split
            // Split a_significand = a_hi * 2^WLO + a_lo (and same for b), then
            //   a*b = a_hi*b_hi * 2^(2*WLO) + (a_hi*b_lo + a_lo*b_hi) * 2^WLO + a_lo*b_lo
            // WLO is chosen to keep each operand at most ceil(WMAN/2) bits wide.
            localparam WLO = (WMAN + 1) / 2;
            localparam WHI = WMAN - WLO;

            // verilator coverage_off
            // Split operand halves: the high halves include the always-1 hidden-bit MSB. The partial
            // products and their sum (mag_src) carry the behaviour and stay covered.
            wire [WLO-1:0] a_lo = a_significand[WLO-1:0];
            wire [WHI-1:0] a_hi = a_significand[WMAN-1:WLO];
            wire [WLO-1:0] b_lo = b_significand[WLO-1:0];
            wire [WHI-1:0] b_hi = b_significand[WMAN-1:WLO];
            // verilator coverage_on

            // Stage 0: register the four partial products and propagate the control payload.
            reg                            s0_valid;
            reg                            s0_sign;
            reg signed [WEXP_UNBIASED-1:0] s0_exp_base;
            reg                            s0_force_zero;
            reg                            s0_force_inf;
            reg [(WLO+WLO)-1:0]            s0_p_ll;
            reg [(WLO+WHI)-1:0]            s0_p_lh;
            reg [(WHI+WLO)-1:0]            s0_p_hl;
            reg [(WHI+WHI)-1:0]            s0_p_hh;

            always @(posedge clk) begin
                if (rst) begin
                    s0_valid <= 1'b0;
                end else begin
                    s0_valid <= in_valid_q;
                end
                s0_sign       <= pre_sign;
                s0_exp_base   <= exp_unbiased_in;
                s0_force_zero <= pre_force_zero;
                s0_force_inf  <= pre_force_inf;
                s0_p_ll       <= a_lo * b_lo;
                s0_p_lh       <= a_lo * b_hi;
                s0_p_hl       <= a_hi * b_lo;
                s0_p_hh       <= a_hi * b_hi;
            end

            // Align and sum. Each partial product is 0-extended to WMAG, then shifted to its place.
            // verilator coverage_off
            // These are the partial products placed into a WMAG-wide field; the zero-extension/zero-shift
            // padding bits are structurally constant. The summed mag_src below is the real product and
            // stays covered.
            wire [WMAG-1:0] hh_ext = {{(WMAG - 2*WHI - 2*WLO){1'b0}}, s0_p_hh, {(2*WLO){1'b0}}};
            wire [WMAG-1:0] lh_ext = {{(WMAG - WLO - WHI - WLO){1'b0}}, s0_p_lh, {WLO{1'b0}}};
            wire [WMAG-1:0] hl_ext = {{(WMAG - WHI - WLO - WLO){1'b0}}, s0_p_hl, {WLO{1'b0}}};
            wire [WMAG-1:0] ll_ext = {{(WMAG - 2*WLO){1'b0}}, s0_p_ll};
            // verilator coverage_on

            assign mag_src            = hh_ext + lh_ext + hl_ext + ll_ext;
            assign mag_src_valid      = s0_valid;
            assign mag_src_sign       = s0_sign;
            assign mag_src_exp_base   = s0_exp_base;
            assign mag_src_force_zero = s0_force_zero;
            assign mag_src_force_inf  = s0_force_inf;
        end
    endgenerate

    // Stage 1: registered product magnitude and packed control state.
    // Keeping the full product registered is intentional: trimming the sticky-only tail saves FFs but moves the tail
    // OR-reduction onto the multiplier output path and measurably hurts fmax, presumably because it weakens retiming.
    reg                            s1_valid;
    reg                            s1_sign;
    reg                 [WMAG-1:0] s1_mag;
    reg signed [WEXP_UNBIASED-1:0] s1_exp_unbiased_base;
    reg                            s1_force_zero;
    reg                            s1_force_inf;

    // A nonzero hidden-bit product has its leading one in one of the two most-significant product bits.
    // Keep the two overlapping sticky reductions separate: sharing s1_sticky_lo saved no resources and hurt fmax.
    wire                            s1_product_high   = s1_mag[WMAG-1];
    // verilator coverage_off
    // s1_exp_adjust is 0 or 1 carried in a WEXP_UNBIASED-wide signed field for the exponent add, so only
    // its low bit can toggle; the high bits are structurally constant. The adjusted sum s1_exp_unbiased
    // below is the real datapath value and stays covered.
    wire signed [WEXP_UNBIASED-1:0] s1_exp_adjust     = s1_product_high ? ONE_EXT : ZERO_EXT;
    // verilator coverage_on
    wire signed [WEXP_UNBIASED-1:0] s1_exp_unbiased   = s1_exp_unbiased_base + s1_exp_adjust;
    wire                 [WMAN-1:0] s1_significand_hi = s1_mag[WMAG-1 -: WMAN];
    wire                 [WMAN-1:0] s1_significand_lo = s1_mag[WMAG-2 -: WMAN];
    wire                            s1_guard_hi       = s1_mag[WMAN-1];
    wire                            s1_round_hi       = s1_mag[WMAN-2];
    wire                            s1_guard_lo       = s1_mag[WMAN-2];
    wire                            s1_round_lo       = s1_mag[WMAN-3];
    wire                            s1_sticky_hi      = |s1_mag[WMAN-3:0];
    wire                            s1_sticky_lo      = |s1_mag[WMAN-4:0];

    _zkf_pack #(
        .WEXP(WEXP), .WMAN(WMAN),
        .STAGE_INPUT(STAGE_PACK), .STAGE_OUTPUT(STAGE_OUTPUT)
    ) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s1_valid),
        .sign(s1_sign),
        .force_zero(s1_force_zero),
        .force_inf(s1_force_inf),
        .exp_unbiased(s1_exp_unbiased),
        .significand(s1_product_high ? s1_significand_hi : s1_significand_lo),
        .guard(s1_product_high ? s1_guard_hi : s1_guard_lo),
        .round(s1_product_high ? s1_round_hi : s1_round_lo),
        .sticky(s1_product_high ? s1_sticky_hi : s1_sticky_lo),
        .out_valid(out_valid),
        .y(y)
    );

    // Reset only stream validity. Payload registers intentionally free-run.
    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= mag_src_valid;
        end
        s1_sign              <= mag_src_sign;
        s1_mag               <= mag_src;
        s1_exp_unbiased_base <= mag_src_exp_base;
        s1_force_zero        <= mag_src_force_zero;
        s1_force_inf         <= mag_src_force_inf;
    end
endmodule

`undef ZKF_MUL_LATENCY
`default_nettype wire
