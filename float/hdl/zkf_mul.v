/// Streamed Zubax Kulibin float multiplier.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Pipeline depth: two stages from in_valid to out_valid.

`default_nettype none

module zkf_mul #(
    parameter WEXP = 6,      // exponent field width
    parameter WMAN = 18      // significand precision including the hidden bit
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y
);
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wman
            _zkf_invalid_wexp_or_wman u_invalid();
        end
    endgenerate

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

    // Stage 1: registered product.
    // Keep the full product registered: trimming the sticky-only tail saves FFs, but moves the tail OR-reduction onto
    // the multiplier output path and measurably hurts fmax in synthesis, presumably because it weakens retiming.
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
            s1_valid <= in_valid;
        end

        s1_sign <= a_sign ^ b_sign;
        s1_mag <= a_significand * b_significand;
        s1_exp_unbiased_base <= exp_unbiased_in;
        s1_force_zero <= result_zero;
        s1_force_inf <= result_inf;
    end
endmodule

`default_nettype wire
