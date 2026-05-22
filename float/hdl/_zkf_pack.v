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
/// STAGE_OUTPUT=1: one register stage at the output.
/// STAGE_OUTPUT=0: the output is combinational, zero cycle latency.
///
/// EXP_IS_BIASED=0: The exp_unbiased port is unbiased and the bias is added here.
/// EXP_IS_BIASED=1: It already carries the signed biased exponent, so the bias add is skipped - for a caller that
///     folded the bias into its own exponent arithmetic to shorten its critical path (e.g. zkf_add:
///     large_exp - normalize_shift is already the biased exponent, avoiding a -BIAS/+BIAS round trip).

`default_nettype none

module _zkf_pack #(
    parameter WEXP          = 6,          // exponent field width
    parameter WMAN          = 18,         // significand precision including the hidden bit
    parameter WEXP_UNBIASED = WEXP + 2,   // signed unbiased exponent width
    parameter EXP_IS_BIASED = 0,          // see above
    parameter STAGE_OUTPUT  = 1           // 1 = registered output (one register stage); 0 = combinational output
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
    wire signed [WEXP_BIASED_EXT-1:0] bias_ext         = {{(WEXP_BIASED_EXT-WEXP){1'b0}}, EXP_BIAS};
    // verilator coverage_on
    wire signed [WEXP_BIASED_EXT-1:0] exp_unbiased_ext = {exp_unbiased[WEXP_UNBIASED-1], exp_unbiased};
    // EXP_IS_BIASED callers pass the signed biased exponent directly (already sign-extended by the wider field), so the
    // bias add is skipped; the parameter is constant so this is a compile-time select, not a runtime mux.
    wire signed [WEXP_BIASED_EXT-1:0] exp_biased_ext = EXP_IS_BIASED ? exp_unbiased_ext : (exp_unbiased_ext + bias_ext);
    wire                   [WEXP-1:0] exp_biased         = exp_biased_ext[WEXP-1:0];
    wire                              exp_underflow_zero = exp_biased_ext[WEXP_BIASED_EXT-1];
    wire                              exp_one_below_min  = ~|exp_biased_ext;
    wire                              exp_biased_high_nonzero;
    generate
        if (WEXP_UNBIASED > WEXP) begin : g_biased_overflow_wide
            assign exp_biased_high_nonzero = |exp_biased_ext[WEXP_UNBIASED-1:WEXP];
        end else begin : g_biased_overflow_min_width
            assign exp_biased_high_nonzero = 1'b0;
        end
    endgenerate
    wire exp_overflow = !exp_underflow_zero && (exp_biased_high_nonzero || (&exp_biased));

    // Single combinational cone feeding one output register (this packer is one register stage). Rounding,
    // round-to-nearest ties-to-even, folds the increment into a single {exp_biased, significand} adder - the full
    // significand including the hidden bit - so a true significand carry-out (significand was all-ones) ripples
    // straight into the exponent without a separate incrementer, while a carry that only fills the hidden bit of a
    // denormalized input stays out of the exponent, matching the reference. A round-carry at exp_biased ==
    // EXP_MAX_FINITE lands the exponent on EXP_INF with fraction 0 - canonical infinity - on the normal path.
    localparam WEXPSIG = WEXP + WMAN;
    wire               round_increment = guard && (round || sticky || significand[0]);
    wire [WEXPSIG-1:0] expsig          = {exp_biased, significand};
    wire [WEXPSIG-1:0] expsig_rounded  = expsig + {{(WEXPSIG-1){1'b0}}, round_increment};
    wire    [WEXP-1:0] exp_rounded     = expsig_rounded[WEXPSIG-1 -: WEXP];
    wire   [WFRAC-1:0] frac_rounded    = expsig_rounded[WFRAC-1:0];
    wire               infinity        = force_inf || exp_overflow;

    // Result classification. force_zero wins over force_inf; a tiny finite magnitude exactly one exponent below the
    // normal range rounds to signed MIN_NORMAL, anything lower to canonical +0.
    wire result_zero       = force_zero || (!force_inf && exp_underflow_zero);
    wire result_infinity   = !result_zero && infinity;
    wire result_min_normal = !result_zero && !force_inf && exp_one_below_min;
    wire result_normal     = !result_zero && !result_infinity && !result_min_normal;

    // Canonicalize by masking instead of a full-width 4:1 output mux: the stored fraction is nonzero only for normal
    // results, so it collapses to an AND-mask; the exponent selects one of three small constants or the rounded
    // exponent; the sign is forced to 0 only for canonical +0. This keeps the wide fraction field off the mux tree.
    wire             out_sign = sign & ~result_zero;
    wire [WEXP-1:0]  out_exp  = result_zero       ? {WEXP{1'b0}} :
                                result_infinity   ? EXP_INF :
                                result_min_normal ? {{(WEXP-1){1'b0}}, 1'b1} :
                                                    exp_rounded;
    wire [WFRAC-1:0] out_frac = frac_rounded & {WFRAC{result_normal}};

    // Output stage. STAGE_OUTPUT=1 registers the packed result (one register stage; reset only touches validity, the
    // payload register free-runs so reset is not on the datapath). STAGE_OUTPUT=0 drives it combinationally so the
    // consumer provides the register, letting a caller shed the packer's output cycle. Special-value canonicalization
    // is folded into out_sign/out_exp/out_frac above.
    generate
        if (STAGE_OUTPUT != 0) begin : g_out_reg
            reg             out_valid_r;
            reg [WFULL-1:0] y_r;
            always @(posedge clk) begin
                if (rst) out_valid_r <= 1'b0;
                else     out_valid_r <= in_valid;
                y_r <= {out_sign, out_exp, out_frac};
            end
            assign out_valid = out_valid_r;
            assign y         = y_r;
        end else begin : g_out_comb
            assign out_valid = in_valid;
            assign y         = {out_sign, out_exp, out_frac};
        end
    endgenerate
endmodule

/// Delay a sideband payload through the single register stage of _zkf_pack.
/// When changing the packer pipeline, update this one as well.
/// The reset can be tied off to zero if the delay is not used for carrying control signals.
module _zkf_pack_delay#(parameter W = 1)(input wire clk, input wire rst, input wire [W-1:0] x, output reg [W-1:0] y);
    always @(posedge clk) begin
        // verilator coverage_off
        if (rst) y <= {W{1'b0}};
        // verilator coverage_on
        else     y <= x;
    end
endmodule

`default_nettype wire
