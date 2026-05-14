/// Streamed Zubax Kulibin float multiplier.
/// The exact product is represented as: (-1)^sign * mag * 2^scale

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
    localparam WFRAC       = WMAN - 1;
    localparam WFULL       = WEXP + WMAN;
    localparam WMAG        = 2 * WMAN;
    localparam WLOG        = $clog2(WMAG);
    localparam WMAN_BITS   = $clog2(WMAN + 1);
    localparam WSCALE_BASE = (WEXP > (WMAN_BITS + 1)) ? WEXP : (WMAN_BITS + 1);
    localparam WSCALE      = WSCALE_BASE + 2;

    localparam          [WEXP-1:0] EXP_BIAS        = {1'b0, {WEXP-1{1'b1}}};
    localparam          [WEXP-1:0] EXP_INF         = {WEXP{1'b1}};
    localparam signed [WSCALE-1:0] WFRAC_EXT       = WFRAC;
    localparam signed [WSCALE-1:0] FORCE_INF_SCALE = {1'b0, {WSCALE-1{1'b1}}};
    localparam          [WLOG-1:0] PRODUCT_LOG2_HI = WMAG - 1;
    localparam          [WLOG-1:0] PRODUCT_LOG2_LO = WMAG - 2;

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

    wire signed [WSCALE-1:0] a_exp_ext        = {{(WSCALE-WEXP){1'b0}}, s1_a_exp};
    wire signed [WSCALE-1:0] b_exp_ext        = {{(WSCALE-WEXP){1'b0}}, s1_b_exp};
    wire signed [WSCALE-1:0] bias_ext         = {{(WSCALE-WEXP){1'b0}}, EXP_BIAS};
    wire signed [WSCALE-1:0] s1_decoded_scale = a_exp_ext + b_exp_ext - (bias_ext <<< 1) - (WFRAC_EXT <<< 1);

    // Stage 2: registered product.
    reg s2_valid;
    reg s2_sign;
    (* keep *) reg [WMAG-1:0] s2_mag;
    reg signed [WSCALE-1:0] s2_scale;
    reg s2_force_zero;
    reg s2_force_inf;

    // A nonzero hidden-bit product has its leading one in one of the two most-significant product bits.
    // Thus we can compute floor(log2(mag)) much simpler than _zkf_ilog2_floor.
    wire            s2_mag_zero  = !s2_mag[WMAG-1] && !s2_mag[WMAG-2];
    wire [WLOG-1:0] s2_mag_flog2 = s2_mag[WMAG-1] ? PRODUCT_LOG2_HI : (s2_mag[WMAG-2] ? PRODUCT_LOG2_LO : {WLOG{1'b0}});

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WMAG(WMAG), .WSCALE(WSCALE), .WLOG(WLOG)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s2_valid),
        .sign(s2_sign),
        .mag(s2_mag),
        .mag_zero(s2_force_zero || s2_mag_zero),
        .mag_flog2(s2_mag_flog2),
        .scale(s2_force_inf ? FORCE_INF_SCALE : s2_scale),
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
        s2_scale <= s1_decoded_scale;
        s2_force_zero <= s1_result_zero;
        s2_force_inf <= s1_result_inf;
    end
endmodule

`default_nettype wire
