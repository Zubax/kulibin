/// Streamed Zubax Kulibin float multiplier.
///
/// Pipeline depth: three stages from in_valid to out_valid:
/// one public input latch, one product stage, and _zkf_pack with one stage.

`default_nettype none

module zkf_mul #(
    parameter WEXP = 6,      // exponent field width
    parameter WMAN = 18      // significand precision including the hidden bit
) (
    input  wire                 clk,
    input  wire                 rst,

    input  wire                 in_valid,
    input  wire [WEXP+WMAN-1:0] a,
    input  wire [WEXP+WMAN-1:0] b,

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

    // Stage 1: input latch. Do not place logic/arithmetic directly on the public input path.
    reg             s1_valid;
    reg [WFULL-1:0] s1_a;
    reg [WFULL-1:0] s1_b;

    wire             s1_a_sign = s1_a[WFULL-1];
    wire             s1_b_sign = s1_b[WFULL-1];
    wire [WEXP-1:0]  s1_a_exp  = s1_a[WFULL-2:WFRAC];
    wire [WEXP-1:0]  s1_b_exp  = s1_b[WFULL-2:WFRAC];
    wire [WFRAC-1:0] s1_a_frac = s1_a[WFRAC-1:0];
    wire [WFRAC-1:0] s1_b_frac = s1_b[WFRAC-1:0];

    wire            s1_a_zero         = s1_a_exp == {WEXP{1'b0}};
    wire            s1_b_zero         = s1_b_exp == {WEXP{1'b0}};
    wire            s1_a_inf          = s1_a_exp == EXP_INF;
    wire            s1_b_inf          = s1_b_exp == EXP_INF;
    wire            s1_result_zero    = s1_a_zero || s1_b_zero;
    wire            s1_result_inf     = !s1_result_zero && (s1_a_inf || s1_b_inf);
    wire [WMAN-1:0] s1_a_significand  = {1'b1, s1_a_frac};
    wire [WMAN-1:0] s1_b_significand  = {1'b1, s1_b_frac};

    wire signed [WEXP_UNBIASED-1:0] a_exp_ext       = {{(WEXP_UNBIASED-WEXP){1'b0}}, s1_a_exp};
    wire signed [WEXP_UNBIASED-1:0] b_exp_ext       = {{(WEXP_UNBIASED-WEXP){1'b0}}, s1_b_exp};
    wire signed [WEXP_UNBIASED-1:0] bias_ext        = {{(WEXP_UNBIASED-WEXP){1'b0}}, EXP_BIAS};
    wire signed [WEXP_UNBIASED-1:0] s1_exp_unbiased = a_exp_ext + b_exp_ext - (bias_ext <<< 1);

    // Stage 2: registered product.
    reg                            s2_valid;
    reg                            s2_sign;
    reg                 [WMAG-1:0] s2_mag;
    reg signed [WEXP_UNBIASED-1:0] s2_exp_unbiased_base;
    reg                            s2_force_zero;
    reg                            s2_force_inf;

    // A nonzero hidden-bit product has its leading one in one of the two most-significant product bits.
    wire                            s2_product_high   = s2_mag[WMAG-1];
    wire signed [WEXP_UNBIASED-1:0] s2_exp_adjust     = s2_product_high ? ONE_EXT : ZERO_EXT;
    wire signed [WEXP_UNBIASED-1:0] s2_exp_unbiased   = s2_exp_unbiased_base + s2_exp_adjust;
    wire                 [WMAN-1:0] s2_significand_hi = s2_mag[WMAG-1 -: WMAN];
    wire                 [WMAN-1:0] s2_significand_lo = s2_mag[WMAG-2 -: WMAN];
    wire                            s2_guard_hi       = s2_mag[WMAN-1];
    wire                            s2_round_hi       = s2_mag[WMAN-2];
    wire                            s2_guard_lo       = s2_mag[WMAN-2];
    wire                            s2_round_lo       = s2_mag[WMAN-3];
    wire                            s2_sticky_hi      = |s2_mag[WMAN-3:0];
    wire                            s2_sticky_lo      = |s2_mag[WMAN-4:0];

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s2_valid),
        .sign(s2_sign),
        .force_zero(s2_force_zero),
        .force_inf(s2_force_inf),
        .exp_unbiased(s2_exp_unbiased),
        .significand(s2_product_high ? s2_significand_hi : s2_significand_lo),
        .guard(s2_product_high ? s2_guard_hi : s2_guard_lo),
        .round(s2_product_high ? s2_round_hi : s2_round_lo),
        .sticky(s2_product_high ? s2_sticky_hi : s2_sticky_lo),
        .out_valid(out_valid),
        .y(y)
    );

    // Reset only stream validity. Payload registers intentionally free-run.
    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
        end else begin
            s1_valid <= in_valid;
            s2_valid <= s1_valid;
        end

        s1_a <= a;
        s1_b <= b;

        s2_sign <= s1_a_sign ^ s1_b_sign;
        s2_mag <= s1_a_significand * s1_b_significand;
        s2_exp_unbiased_base <= s1_exp_unbiased;
        s2_force_zero <= s1_result_zero;
        s2_force_inf <= s1_result_inf;
    end
endmodule

`default_nettype wire
