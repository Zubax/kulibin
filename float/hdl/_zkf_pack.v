/// Pack an exact scaled unsigned integer magnitude into Zubax Kulibin float with saturation and rounding to nearest.
/// The exact input value is:
///
///     (-1)^sign * mag * 2^scale
///
/// The output is canonical zero for zero/underflow, round-to-nearest ties-to-even for normal values,
/// and signed saturation for exponent overflow.

`default_nettype none

module _zkf_pack #(
    parameter WEXP = 8,              // exponent field width
    parameter WMAN = 16,             // significand precision including the hidden bit
    parameter WMAG = 2 * WMAN,       // input magnitude width; usually set by the instantiator
    parameter WSCALE = 1             // signed binary scale width; always set by the instantiator depending on usage
)(
    input  wire clk,
    input  wire rst,

    input  wire                     in_valid,
    input  wire                     sign,
    input  wire          [WMAG-1:0] mag,
    input  wire signed [WSCALE-1:0] scale,

    output reg                   out_valid,
    output reg  [WEXP+WMAN-1:0]  y,
    output reg                   saturated
);
    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;
    localparam WLOG = (WMAG <= 2) ? 1 : $clog2(WMAG);
    localparam WEXP_INT = WSCALE + WLOG + WEXP + 4;

    localparam [WEXP-1:0] EXP_BIAS = {1'b0, {WEXP-1{1'b1}}};
    localparam [WEXP-1:0] EXP_MAX = {WEXP{1'b1}};

    wire mag_zero;
    wire [WLOG-1:0] mag_log2;
    _zkf_ilog2_floor #(.W(WMAG), .WINDEX(WLOG)) u_ilog2_floor (.x(mag), .zero(mag_zero), .y(mag_log2));

    reg s1_valid;
    reg s1_sign;
    reg s1_zero;
    reg [WMAG-1:0] s1_mag;
    reg signed [WSCALE-1:0] s1_scale;
    reg [WLOG-1:0] s1_log2;

    wire signed [WEXP_INT-1:0] bias_ext = {{(WEXP_INT-WEXP){1'b0}}, EXP_BIAS};
    wire signed [WEXP_INT-1:0] exp_max_ext = {{(WEXP_INT-WEXP){1'b0}}, EXP_MAX};
    wire signed [WEXP_INT-1:0] s1_scale_ext = {{(WEXP_INT-WSCALE){s1_scale[WSCALE-1]}}, s1_scale};
    wire signed [WEXP_INT-1:0] s1_log2_ext = {{(WEXP_INT-WLOG){1'b0}}, s1_log2};
    wire signed [WEXP_INT-1:0] s1_exp_biased = s1_scale_ext + s1_log2_ext + bias_ext;

    localparam WALIGN = WMAG + WMAN + 1;
    wire [WALIGN-1:0] s1_aligned = {s1_mag, {WMAN+1{1'b0}}} >> s1_log2;
    wire [WMAN-1:0] s1_significand = s1_aligned[WMAN+1:2];
    wire s1_guard = s1_aligned[1];
    wire s1_round = s1_aligned[0];

    wire [WMAG-1:0] s1_sticky_bits;
    genvar i_sticky;
    generate
        for (i_sticky = 0; i_sticky < WMAG; i_sticky = i_sticky + 1) begin : g_sticky
            if ((i_sticky + WMAN + 2) < WMAG) begin : g_used
                localparam [WLOG-1:0] THRESHOLD = i_sticky + WMAN + 2;
                assign s1_sticky_bits[i_sticky] = s1_mag[i_sticky] && (s1_log2 >= THRESHOLD);
            end else begin : g_unused
                assign s1_sticky_bits[i_sticky] = 1'b0;
            end
        end
    endgenerate
    wire s1_sticky = |s1_sticky_bits;

    reg s2_valid;
    reg s2_sign;
    reg s2_zero;
    reg s2_underflow;
    reg signed [WEXP_INT-1:0] s2_exp_biased;
    reg [WMAN-1:0] s2_significand;
    reg s2_guard;
    reg s2_round;
    reg s2_sticky;

    wire s2_round_increment = s2_guard && (s2_round || s2_sticky || s2_significand[0]);
    wire [WMAN:0] s2_rounded_ext = {1'b0, s2_significand} + {{WMAN{1'b0}}, s2_round_increment};
    wire s2_round_carry = s2_rounded_ext[WMAN];
    wire [WMAN-1:0] s2_rounded_significand =
        s2_round_carry ? s2_rounded_ext[WMAN:1] : s2_rounded_ext[WMAN-1:0];
    wire signed [WEXP_INT-1:0] s2_exp_rounded =
        s2_exp_biased + {{(WEXP_INT-1){1'b0}}, s2_round_carry};

    reg s3_valid;
    reg s3_sign;
    reg s3_zero;
    reg s3_underflow;
    reg signed [WEXP_INT-1:0] s3_exp_biased;
    reg [WMAN-1:0] s3_significand;

    wire s3_result_zero = s3_zero || s3_underflow;
    wire s3_result_saturated = !s3_result_zero && (s3_exp_biased > exp_max_ext);
    wire [WFULL-1:0] s3_zero_y = {WFULL{1'b0}};
    wire [WFULL-1:0] s3_saturated_y = {s3_sign, EXP_MAX, {WFRAC{1'b1}}};
    wire [WFULL-1:0] s3_normal_y = {s3_sign, s3_exp_biased[WEXP-1:0], s3_significand[WFRAC-1:0]};
    wire [WFULL-1:0] s3_y = s3_result_zero ? s3_zero_y : (s3_result_saturated ? s3_saturated_y : s3_normal_y);

    reg s4_valid;
    reg [WFULL-1:0] s4_y;
    reg s4_saturated;

    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s1_sign <= 1'b0;
            s1_zero <= 1'b1;
            s1_mag <= 0;
            s1_scale <= 0;
            s1_log2 <= 0;

            s2_valid <= 1'b0;
            s2_sign <= 1'b0;
            s2_zero <= 1'b1;
            s2_underflow <= 1'b1;
            s2_exp_biased <= 0;
            s2_significand <= 0;
            s2_guard <= 1'b0;
            s2_round <= 1'b0;
            s2_sticky <= 1'b0;

            s3_valid <= 1'b0;
            s3_sign <= 1'b0;
            s3_zero <= 1'b1;
            s3_underflow <= 1'b1;
            s3_exp_biased <= 0;
            s3_significand <= 0;

            s4_valid <= 1'b0;
            s4_y <= 0;
            s4_saturated <= 1'b0;

            out_valid <= 1'b0;
            y <= 0;
            saturated <= 1'b0;
        end else begin
            s1_valid <= in_valid;
            s1_sign <= sign;
            s1_zero <= mag_zero;
            s1_mag <= mag;
            s1_scale <= scale;
            s1_log2 <= mag_log2;

            s2_valid <= s1_valid;
            s2_sign <= s1_sign;
            s2_zero <= s1_zero;
            s2_underflow <= (s1_exp_biased <= 0);
            s2_exp_biased <= s1_exp_biased;
            s2_significand <= s1_significand;
            s2_guard <= s1_guard;
            s2_round <= s1_round;
            s2_sticky <= s1_sticky;

            s3_valid <= s2_valid;
            s3_sign <= s2_sign;
            s3_zero <= s2_zero;
            s3_underflow <= s2_underflow;
            s3_exp_biased <= s2_exp_rounded;
            s3_significand <= s2_rounded_significand;

            s4_valid <= s3_valid;
            s4_y <= s3_y;
            s4_saturated <= s3_result_saturated;

            out_valid <= s4_valid;
            y <= s4_y;
            saturated <= s4_saturated;
        end
    end
endmodule

`default_nettype wire
