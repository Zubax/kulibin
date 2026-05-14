/// Pack a normalized unsigned significand into float with infinity and rounding to nearest.
/// The exact finite input value before rounding is: (-1)^sign * 1.significand_fraction * 2^exp_unbiased
///
/// The significand input includes the hidden bit. The guard/round/sticky inputs carry the discarded tail bits.
/// force_zero and force_inf override the finite value; force_zero wins if both are asserted.
///
/// The output is canonical zero for zero/underflow, round-to-nearest ties-to-even for normal values,
/// and canonical signed infinity for exponent overflow.
///
/// All inputs and outputs are latched -- no combinational logic on external interfaces.
/// Pipeline depth: two stages from in_valid to out_valid.

`default_nettype none

module _zkf_pack #(
    parameter WEXP          = 6,          // exponent field width
    parameter WMAN          = 18,         // significand precision including the hidden bit
    parameter WEXP_UNBIASED = WEXP + 2    // signed unbiased exponent width
)(
    input  wire clk,
    input  wire rst,

    input  wire                            in_valid,
    input  wire                            sign,
    input  wire                            force_zero,
    input  wire                            force_inf,
    input  wire signed [WEXP_UNBIASED-1:0] exp_unbiased,
    input  wire                 [WMAN-1:0] significand,
    input  wire                            guard,
    input  wire                            round,
    input  wire                            sticky,

    output reg                     out_valid,
    output reg     [WEXP+WMAN-1:0] y
);
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wman
            _zkf_invalid_wexp_or_wman u_invalid();
        end
    endgenerate

    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;

    localparam [WEXP-1:0] EXP_BIAS       = {1'b0, {WEXP-1{1'b1}}};
    localparam [WEXP-1:0] EXP_INF        = {WEXP{1'b1}};
    localparam [WEXP-1:0] EXP_MAX_FINITE = EXP_INF - {{(WEXP-1){1'b0}}, 1'b1};

    // Stage 1: input sample.
    reg                            s1_valid;
    reg                            s1_sign;
    reg                            s1_force_zero;
    reg                            s1_force_inf;
    reg signed [WEXP_UNBIASED-1:0] s1_exp_unbiased;
    reg                 [WMAN-1:0] s1_significand;
    reg                            s1_guard;
    reg                            s1_round;
    reg                            s1_sticky;

    // Stage 1 combinational exponent classification. Underflow is decided before rounding per the format spec.
    wire signed [WEXP_UNBIASED-1:0] bias_ext           = {{(WEXP_UNBIASED-WEXP){1'b0}}, EXP_BIAS};
    wire signed [WEXP_UNBIASED-1:0] exp_max_finite_ext = {{(WEXP_UNBIASED-WEXP){1'b0}}, EXP_MAX_FINITE};
    wire signed [WEXP_UNBIASED-1:0] one_ext            = {{(WEXP_UNBIASED-1){1'b0}}, 1'b1};
    wire signed [WEXP_UNBIASED-1:0] min_exp_unbiased   = one_ext - bias_ext;
    wire signed [WEXP_UNBIASED-1:0] max_exp_unbiased   = exp_max_finite_ext - bias_ext;
    wire signed [WEXP_UNBIASED-1:0] s1_exp_biased_ext  = s1_exp_unbiased + bias_ext;
    wire             [WEXP-1:0]     s1_exp_biased      = s1_exp_biased_ext[WEXP-1:0];
    wire                            s1_exp_underflow   = s1_exp_unbiased < min_exp_unbiased;
    wire                            s1_exp_overflow    = s1_exp_unbiased > max_exp_unbiased;

    // Stage 2: pre-round normalized value.
    reg            s2_valid;
    reg            s2_sign;
    reg            s2_force_zero;
    reg            s2_force_inf;
    reg            s2_underflow;
    reg            s2_overflow;
    reg [WEXP-1:0] s2_exp_biased;
    reg [WMAN-1:0] s2_significand;
    reg            s2_guard;
    reg            s2_round;
    reg            s2_sticky;

    // Stage 2 combinational rounding, round-to-nearest ties-to-even.
    wire            s2_round_increment     = s2_guard && (s2_round || s2_sticky || s2_significand[0]);
    wire [WMAN:0]   s2_rounded_ext         = {1'b0, s2_significand} + {{WMAN{1'b0}}, s2_round_increment};
    wire            s2_round_carry         = s2_rounded_ext[WMAN];
    wire            s2_exp_round_overflow  = (s2_exp_biased == EXP_MAX_FINITE) && s2_round_carry;
    wire            s2_infinity            = s2_force_inf || s2_overflow || s2_exp_round_overflow;
    wire [WMAN-1:0] s2_rounded_significand = s2_round_carry ? s2_rounded_ext[WMAN:1] : s2_rounded_ext[WMAN-1:0];
    wire [WEXP-1:0] s2_exp_rounded         = s2_exp_biased + {{(WEXP-1){1'b0}}, s2_round_carry};

    // Final packing is deliberately outside the reset branch; only validity is reset.
    wire             s2_result_zero     = s2_force_zero || (!s2_force_inf && s2_underflow);
    wire             s2_result_infinity = !s2_result_zero && s2_infinity;
    wire [WFULL-1:0] s2_zero_y          = {WFULL{1'b0}};
    wire [WFULL-1:0] s2_infinity_y      = {s2_sign, EXP_INF, {WFRAC{1'b0}}};
    wire [WFULL-1:0] s2_normal_y        = {s2_sign, s2_exp_rounded, s2_rounded_significand[WFRAC-1:0]};

    // Reset only stream validity. Payload registers intentionally free-run so reset is not on the datapath.
    always @(posedge clk) begin
        if (rst) begin
            s1_valid  <= 1'b0;
            s2_valid  <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            s1_valid  <= in_valid;
            s2_valid  <= s1_valid;
            out_valid <= s2_valid;
        end

        // Stage 1 capture. Do not place logic/arithmetic directly on the input path.
        s1_sign          <= sign;
        s1_force_zero    <= force_zero;
        s1_force_inf     <= force_inf;
        s1_exp_unbiased  <= exp_unbiased;
        s1_significand   <= significand;
        s1_guard         <= guard;
        s1_round         <= round;
        s1_sticky        <= sticky;

        // Stage 2 capture: pre-round normalized value.
        s2_sign         <= s1_sign;
        s2_force_zero   <= s1_force_zero;
        s2_force_inf    <= s1_force_inf;
        s2_underflow    <= s1_exp_underflow;
        s2_overflow     <= s1_exp_overflow;
        s2_exp_biased   <= s1_exp_biased;
        s2_significand  <= s1_significand;
        s2_guard        <= s1_guard;
        s2_round        <= s1_round;
        s2_sticky       <= s1_sticky;

        // Output capture.
        y <= s2_result_zero ? s2_zero_y : (s2_result_infinity ? s2_infinity_y : s2_normal_y);
    end
endmodule

/// Delay a sideband payload by the same number of cycles as _zkf_pack.
/// When changing the packer pipeline, update this one as well.
/// Pipeline depth: two stages, matching _zkf_pack.
/// The reset can be tied off to zero if the delay is not used for carrying control signals.
module _zkf_pack_delay#(parameter W = 1)(input wire clk, input wire rst, input wire [W-1:0] x, output reg [W-1:0] y);
    reg [W-1:0] s1;
    reg [W-1:0] s2;
    always @(posedge clk) begin
        if (rst) begin
            s1 <= {W{1'b0}};
            s2 <= {W{1'b0}};
            y  <= {W{1'b0}};
        end else begin
            s1 <= x;
            s2 <= s1;
            y  <= s2;
        end
    end
endmodule

`default_nettype wire
