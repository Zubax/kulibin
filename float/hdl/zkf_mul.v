/// Streamed Zubax Kulibin float multiplier.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Register stages: 3 (EXTRA_STAGES=0) or 4 (EXTRA_STAGES>=1) end-to-end.
///
/// EXTRA_STAGES=0: single-cycle multiplication. The DSP cascade (e.g. 4*MULT18X18D + 2*ALU54B for WMAN=36 on ECP5)
///   is one combinational hop into the s1_mag register. Use this when the inferred cascade closes timing in one cycle.
///
/// EXTRA_STAGES>=1: split the product into a 2*2 grid of (ceil(WMAN/2)) wide partial products, register them,
///   then sum in the next cycle. Synthesis tools absorb the partial-product registers as DSP output registers and
///   the sum as the ALU54B-style cascade, splitting the chain across two clock periods. Costs one extra pipeline
///   cycle of latency. Values above 1 are treated as 1; further splits are reserved for future expansion.

`default_nettype none

module zkf_mul #(
    parameter WEXP         = 6,    // exponent field width
    parameter WMAN         = 18,   // significand precision including the hidden bit
    parameter EXTRA_STAGES = 0     // 0 = single-cycle product; >=1 = split DSP cascade (+1 cycle)
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

    // Operand decode/classification.
    wire             a_sign = a[WFULL-1];
    wire             b_sign = b[WFULL-1];
    wire [WEXP-1:0]  a_exp  = a[WFULL-2:WFRAC];
    wire [WEXP-1:0]  b_exp  = b[WFULL-2:WFRAC];
    wire [WFRAC-1:0] a_frac = a[WFRAC-1:0];
    wire [WFRAC-1:0] b_frac = b[WFRAC-1:0];

    wire            a_zero        = a_exp == {WEXP{1'b0}};
    wire            b_zero        = b_exp == {WEXP{1'b0}};
    wire            a_inf         = a_exp == EXP_INF;
    wire            b_inf         = b_exp == EXP_INF;
    wire            result_zero   = a_zero || b_zero;
    wire            result_inf    = !result_zero && (a_inf || b_inf);
    wire [WMAN-1:0] a_significand = {1'b1, a_frac};
    wire [WMAN-1:0] b_significand = {1'b1, b_frac};

    wire signed [WEXP_UNBIASED-1:0] a_exp_ext       = {{(WEXP_UNBIASED-WEXP){1'b0}}, a_exp};
    wire signed [WEXP_UNBIASED-1:0] b_exp_ext       = {{(WEXP_UNBIASED-WEXP){1'b0}}, b_exp};
    wire signed [WEXP_UNBIASED-1:0] bias_ext        = {{(WEXP_UNBIASED-WEXP){1'b0}}, EXP_BIAS};
    wire signed [WEXP_UNBIASED-1:0] exp_unbiased_in = a_exp_ext + b_exp_ext - (bias_ext <<< 1);

    wire pre_sign       = a_sign ^ b_sign;
    wire pre_force_zero = result_zero;
    wire pre_force_inf  = result_inf;

    // -- Magnitude source. ES=0 drives the combinational a*b straight into the s1 capture;
    // ES>=1 registers a 2*2 grid of partial products and combines them in the next cycle.
    wire                            mag_src_valid;
    wire                            mag_src_sign;
    wire signed [WEXP_UNBIASED-1:0] mag_src_exp_base;
    wire                            mag_src_force_zero;
    wire                            mag_src_force_inf;
    wire                 [WMAG-1:0] mag_src;

    generate
        if (EXTRA_STAGES == 0) begin : g_mul_unsplit
            assign mag_src            = a_significand * b_significand;
            assign mag_src_valid      = in_valid;
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

            wire [WLO-1:0] a_lo = a_significand[WLO-1:0];
            wire [WHI-1:0] a_hi = a_significand[WMAN-1:WLO];
            wire [WLO-1:0] b_lo = b_significand[WLO-1:0];
            wire [WHI-1:0] b_hi = b_significand[WMAN-1:WLO];

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
                    s0_valid <= in_valid;
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
            wire [WMAG-1:0] hh_ext = {{(WMAG - 2*WHI - 2*WLO){1'b0}}, s0_p_hh, {(2*WLO){1'b0}}};
            wire [WMAG-1:0] lh_ext = {{(WMAG - WLO - WHI - WLO){1'b0}}, s0_p_lh, {WLO{1'b0}}};
            wire [WMAG-1:0] hl_ext = {{(WMAG - WHI - WLO - WLO){1'b0}}, s0_p_hl, {WLO{1'b0}}};
            wire [WMAG-1:0] ll_ext = {{(WMAG - 2*WLO){1'b0}}, s0_p_ll};

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
    wire signed [WEXP_UNBIASED-1:0] s1_exp_adjust     = s1_product_high ? ONE_EXT : ZERO_EXT;
    wire signed [WEXP_UNBIASED-1:0] s1_exp_unbiased   = s1_exp_unbiased_base + s1_exp_adjust;
    wire                 [WMAN-1:0] s1_significand_hi = s1_mag[WMAG-1 -: WMAN];
    wire                 [WMAN-1:0] s1_significand_lo = s1_mag[WMAG-2 -: WMAN];
    wire                            s1_guard_hi       = s1_mag[WMAN-1];
    wire                            s1_round_hi       = s1_mag[WMAN-2];
    wire                            s1_guard_lo       = s1_mag[WMAN-2];
    wire                            s1_round_lo       = s1_mag[WMAN-3];
    wire                            s1_sticky_hi      = |s1_mag[WMAN-3:0];
    wire                            s1_sticky_lo      = |s1_mag[WMAN-4:0];

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN)) u_pack (
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

`default_nettype wire
