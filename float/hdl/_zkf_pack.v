/// Pack a normalized unsigned significand into float with infinity and rounding to nearest.
/// The exact finite input value before rounding is: (-1)^sign * 1.significand_fraction * 2^exp_unbiased
///
/// The significand input includes the hidden bit. The guard/round/sticky inputs carry the discarded tail bits.
/// force_zero and force_inf override the finite value; force_zero wins if both are asserted.
///
/// The output is canonical zero for zero or finite magnitudes below 0.5*MIN_NORMAL, signed MIN_NORMAL for finite
/// magnitudes at or above that boundary but below MIN_NORMAL, round-to-nearest ties-to-even for normal values, and
/// canonical signed infinity for exponent overflow. Subnormals are not generated.
///
/// Two register stages. Inputs are not latched directly, but the outputs are.

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

    output reg                 out_valid,
    output reg [WEXP+WMAN-1:0] y
);
    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wman
            _zkf_invalid_wexp_or_wman u_invalid();
        end
    endgenerate
    // verilator coverage_on

    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;
    localparam WEXP_BIASED_EXT = WEXP_UNBIASED + 1;

    localparam [WEXP-1:0] EXP_BIAS       = {1'b0, {WEXP-1{1'b1}}};
    localparam [WEXP-1:0] EXP_INF        = {WEXP{1'b1}};
    localparam [WEXP-1:0] EXP_MAX_FINITE = EXP_INF - {{(WEXP-1){1'b0}}, 1'b1};

    // Input combinational exponent classification. Values exactly one exponent below the normal range are at or above
    // the zero/MIN_NORMAL midpoint, so they round directly to MIN_NORMAL. Lower exponents round to canonical zero.
    // bias_ext is a compile-time-constant bias widened with constant padding.
    // verilator coverage_off
    wire signed [WEXP_BIASED_EXT-1:0] bias_ext            = {{(WEXP_BIASED_EXT-WEXP){1'b0}}, EXP_BIAS};
    // verilator coverage_on
    wire signed [WEXP_BIASED_EXT-1:0] exp_unbiased_ext    = {exp_unbiased[WEXP_UNBIASED-1], exp_unbiased};
    wire signed [WEXP_BIASED_EXT-1:0] exp_biased_ext      = exp_unbiased_ext + bias_ext;
    wire                   [WEXP-1:0] exp_biased          = exp_biased_ext[WEXP-1:0];
    wire                              exp_underflow_zero  = exp_biased_ext[WEXP_BIASED_EXT-1];
    wire                              exp_one_below_min   = ~|exp_biased_ext;
    wire                              exp_biased_high_nonzero;
    generate
        if (WEXP_UNBIASED > WEXP) begin : g_biased_overflow_wide
            assign exp_biased_high_nonzero = |exp_biased_ext[WEXP_UNBIASED-1:WEXP];
        end else begin : g_biased_overflow_min_width
            assign exp_biased_high_nonzero = 1'b0;
        end
    endgenerate
    wire exp_overflow = !exp_underflow_zero && (exp_biased_high_nonzero || (&exp_biased));

    // Stage 1: pre-round normalized value.
    reg            s1_valid;
    reg            s1_sign;
    reg            s1_force_zero;
    reg            s1_force_inf;
    reg            s1_underflow_zero;
    reg            s1_one_below_min;
    reg            s1_overflow;
    reg [WEXP-1:0] s1_exp_biased;
    reg [WMAN-1:0] s1_significand;
    reg            s1_guard;
    reg            s1_round;
    reg            s1_sticky;

    // Stage 1 combinational rounding, round-to-nearest ties-to-even. The increment is folded into a single
    // {exp_biased, significand} adder - the full significand including the hidden bit - so a true significand
    // carry-out (significand was all-ones) ripples straight into the exponent without a separate exponent
    // incrementer or carry-select mux, while a carry that only fills the hidden bit (denormalized significand input)
    // stays out of the exponent, matching the reference. A round-carry at exp_biased == EXP_MAX_FINITE thus lands the
    // exponent on EXP_INF with fraction 0 - canonical infinity - without consulting an explicit overflow flag.
    localparam WEXPSIG = WEXP + WMAN;
    wire               s1_round_increment = s1_guard && (s1_round || s1_sticky || s1_significand[0]);
    wire [WEXPSIG-1:0] s1_expsig          = {s1_exp_biased, s1_significand};
    wire [WEXPSIG-1:0] s1_expsig_rounded  = s1_expsig + {{(WEXPSIG-1){1'b0}}, s1_round_increment};
    wire    [WEXP-1:0] s1_exp_rounded     = s1_expsig_rounded[WEXPSIG-1 -: WEXP];
    wire   [WFRAC-1:0] s1_frac_rounded    = s1_expsig_rounded[WFRAC-1:0];
    wire               s1_infinity        = s1_force_inf || s1_overflow;

    // Result classification. force_zero wins over force_inf; a tiny finite magnitude exactly one exponent below the
    // normal range rounds to signed MIN_NORMAL, anything lower to canonical +0.
    wire s1_result_zero       = s1_force_zero || (!s1_force_inf && s1_underflow_zero);
    wire s1_result_infinity   = !s1_result_zero && s1_infinity;
    wire s1_result_min_normal = !s1_result_zero && !s1_force_inf && s1_one_below_min;
    wire s1_result_normal     = !s1_result_zero && !s1_result_infinity && !s1_result_min_normal;

    // Canonicalize by masking instead of a full-width 4:1 output mux: the stored fraction is nonzero only for normal
    // results, so it collapses to an AND-mask; the exponent selects one of three small constants or the rounded
    // exponent; the sign is forced to 0 only for canonical +0. This keeps the wide fraction field off the mux tree.
    wire             out_sign = s1_sign & ~s1_result_zero;
    wire [WEXP-1:0]  out_exp  = s1_result_zero       ? {WEXP{1'b0}} :
                                s1_result_infinity   ? EXP_INF :
                                s1_result_min_normal ? {{(WEXP-1){1'b0}}, 1'b1} :
                                                       s1_exp_rounded;
    wire [WFRAC-1:0] out_frac = s1_frac_rounded & {WFRAC{s1_result_normal}};

    // Reset only stream validity. Payload registers intentionally free-run so reset is not on the datapath.
    always @(posedge clk) begin
        if (rst) begin
            s1_valid  <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            s1_valid  <= in_valid;
            out_valid <= s1_valid;
        end

        // Stage 1 capture: pre-round normalized value.
        s1_sign                <= sign;
        s1_force_zero          <= force_zero;
        s1_force_inf           <= force_inf;
        s1_underflow_zero      <= exp_underflow_zero;
        s1_one_below_min       <= exp_one_below_min;
        s1_overflow            <= exp_overflow;
        s1_exp_biased          <= exp_biased;
        s1_significand         <= significand;
        s1_guard               <= guard;
        s1_round               <= round;
        s1_sticky              <= sticky;

        // Output capture. Special-value canonicalization is folded into out_sign/out_exp/out_frac above.
        y <= {out_sign, out_exp, out_frac};
    end
endmodule

/// Delay a sideband payload through the same two register stages as _zkf_pack.
/// When changing the packer pipeline, update this one as well.
/// The reset can be tied off to zero if the delay is not used for carrying control signals.
module _zkf_pack_delay#(parameter W = 1)(input wire clk, input wire rst, input wire [W-1:0] x, output reg [W-1:0] y);
    reg [W-1:0] s1;
    always @(posedge clk) begin
        // verilator coverage_off
        if (rst) begin
            s1 <= {W{1'b0}};
            y  <= {W{1'b0}};
        // verilator coverage_on
        end else begin
            s1 <= x;
            y  <= s1;
        end
    end
endmodule

`default_nettype wire
