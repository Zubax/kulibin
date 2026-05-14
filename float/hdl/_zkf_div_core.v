/// Internal quotient generator for Zubax Kulibin float division.
/// The exact quotient is approximated for packing as: (-1)^sign * mag * 2^scale
///
/// The quotient bits are produced by an unrolled radix-4 restoring divider.
/// The final partial remainder is exposed as well since it is a byproduct that is occasionally useful.
///
/// This module does not have an input latch, since it is internal -- inputs feed combinational circuit directly.
/// Public modules should take that into account if connecting their inputs directly to the inputs of this module.
/// The outputs are not registered either -- combinational paths exposed.
///
/// Pipeline depth: WMAN+4+((WMAN+4)%2) stages from in_valid to out_valid:
/// two stages per radix-4 quotient digit. Throughput is one sample per cycle.

`default_nettype none

module _zkf_div_core #(
    parameter WEXP         = 6,      // exponent field width
    parameter WMAN         = 18,     // significand precision including the hidden bit
    parameter QFRAC_BASE   = WMAN + 4,
    parameter QFRAC        = QFRAC_BASE + (QFRAC_BASE % 2),
    parameter QWMAG        = QFRAC + 2,
    parameter QWLOG        = $clog2(QWMAG),
    parameter WQFRAC_BITS  = $clog2(QFRAC + 2),
    parameter WSCALE_BASE  = (WEXP > WQFRAC_BITS) ? WEXP : WQFRAC_BITS,
    parameter WSCALE       = WSCALE_BASE + 2
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,

    output wire                     out_valid,
    output wire                     sign,
    output wire         [QWMAG-1:0] mag,
    output wire                     mag_zero,
    output wire         [QWLOG-1:0] mag_flog2,
    output wire signed [WSCALE-1:0] scale,
    output wire                     div0,
    output wire          [WMAN-1:0] partial_rem
);
    localparam WFRAC   = WMAN - 1;
    localparam WFULL   = WEXP + WMAN;
    localparam QSTAGES = QFRAC / 2;
    localparam QRAW    = QFRAC + 1;

    // QRAW contains one integer quotient bit followed by QFRAC fractional bits.
    // QWMAG adds one sticky bit below the packer's round bit.
    localparam          [WEXP-1:0] EXP_INF         = {WEXP{1'b1}};
    localparam signed [WSCALE-1:0] QFRAC_PLUS_ONE  = QFRAC + 1;
    localparam signed [WSCALE-1:0] FORCE_INF_SCALE = {1'b0, {WSCALE-1{1'b1}}};
    localparam         [QWLOG-1:0] MAG_LOG2_HI     = QFRAC + 1;
    localparam         [QWLOG-1:0] MAG_LOG2_LO     = QFRAC;

    wire             a_sign = a[WFULL-1];
    wire             b_sign = b[WFULL-1];
    wire  [WEXP-1:0] a_exp  = a[WFULL-2:WFRAC];
    wire  [WEXP-1:0] b_exp  = b[WFULL-2:WFRAC];
    wire [WFRAC-1:0] a_frac = a[WFRAC-1:0];
    wire [WFRAC-1:0] b_frac = b[WFRAC-1:0];

    // Decode and canonicalize special cases into force-zero/force-infinity controls for _zkf_pack.
    // The quotient core still free-runs for all encodings; special cases override the packed result.
    wire            a_zero        = a_exp == {WEXP{1'b0}};
    wire            b_zero        = b_exp == {WEXP{1'b0}};
    wire            a_inf         = a_exp == EXP_INF;
    wire            b_inf         = b_exp == EXP_INF;
    wire            result_zero   = a_zero || b_inf;
    wire            result_inf    = !a_zero && !b_inf && (b_zero || a_inf);
    wire            result_sign   = b_zero ? a_sign : (a_sign ^ b_sign);
    wire [WMAN-1:0] a_significand = {1'b1, a_frac};
    wire [WMAN-1:0] b_significand = {1'b1, b_frac};

    // Emit the integer quotient bit before the radix-4 stages. Since both significands are in [1, 2),
    // this bit is the only possible integer part, and the initial remainder is strictly below the denominator.
    wire            initial_bit   = a_significand >= b_significand;
    wire [WMAN-1:0] initial_rem   = initial_bit ? (a_significand - b_significand) : a_significand;

    // The raw quotient magnitude is scaled as floor((sig_a / sig_b) * 2^QFRAC), plus sticky.
    // _zkf_pack later adds floor(log2(mag)), so the base scale subtracts QFRAC+1.
    wire signed [WSCALE-1:0] a_exp_ext     = {{(WSCALE-WEXP){1'b0}}, a_exp};
    wire signed [WSCALE-1:0] b_exp_ext     = {{(WSCALE-WEXP){1'b0}}, b_exp};
    wire signed [WSCALE-1:0] decoded_scale = a_exp_ext - b_exp_ext - QFRAC_PLUS_ONE;

    // Each radix-4 quotient digit uses two pipeline registers:
    // p_* captures the digit selection and chosen subtrahend, r_* commits the subtract and appends the digit.
    reg                     r_valid      [1:QSTAGES];
    reg                     r_sign       [1:QSTAGES];
    reg signed [WSCALE-1:0] r_scale      [1:QSTAGES];
    reg                     r_force_zero [1:QSTAGES];
    reg                     r_force_inf  [1:QSTAGES];
    reg                     r_div0       [1:QSTAGES];
    reg          [WMAN-1:0] r_den        [1:QSTAGES];
    reg          [WMAN-1:0] r_rem        [1:QSTAGES];
    reg          [QRAW-1:0] r_raw        [1:QSTAGES];

    reg                     p_valid      [1:QSTAGES];
    reg                     p_sign       [1:QSTAGES];
    reg signed [WSCALE-1:0] p_scale      [1:QSTAGES];
    reg                     p_force_zero [1:QSTAGES];
    reg                     p_force_inf  [1:QSTAGES];
    reg                     p_div0       [1:QSTAGES];
    reg          [WMAN-1:0] p_den        [1:QSTAGES];
    reg        [WMAN+1:0]   p_rem4       [1:QSTAGES];
    reg          [QRAW-1:0] p_raw        [1:QSTAGES];
    reg               [1:0] p_digit      [1:QSTAGES];
    reg        [WMAN+1:0]   p_sub        [1:QSTAGES];

    genvar i_stage;
    generate
        for (i_stage = 1; i_stage <= QSTAGES; i_stage = i_stage + 1) begin : g_stage
            // Stage 1 folds the former preparation register into the first radix-4 select stage.
            // Later stages source their state from the previous committed r_* stage.
            wire                     source_valid;
            wire                     source_sign;
            wire signed [WSCALE-1:0] source_scale;
            wire                     source_force_zero;
            wire                     source_force_inf;
            wire                     source_div0;
            wire          [WMAN-1:0] source_den;
            wire          [WMAN-1:0] source_rem;
            wire          [QRAW-1:0] source_raw;

            if (i_stage == 1) begin : g_input_source
                assign source_valid      = in_valid;
                assign source_sign       = result_sign;
                assign source_scale      = decoded_scale;
                assign source_force_zero = result_zero;
                assign source_force_inf  = result_inf;
                assign source_div0       = b_zero;
                assign source_den        = b_significand;
                assign source_rem        = initial_rem;
                assign source_raw        = {{QFRAC{1'b0}}, initial_bit};
            end else begin : g_pipeline_source
                assign source_valid      = r_valid[i_stage-1];
                assign source_sign       = r_sign[i_stage-1];
                assign source_scale      = r_scale[i_stage-1];
                assign source_force_zero = r_force_zero[i_stage-1];
                assign source_force_inf  = r_force_inf[i_stage-1];
                assign source_div0       = r_div0[i_stage-1];
                assign source_den        = r_den[i_stage-1];
                assign source_rem        = r_rem[i_stage-1];
                assign source_raw        = r_raw[i_stage-1];
            end

            wire [WMAN+1:0] selected_rem4;
            wire      [1:0] selected_digit;
            wire [WMAN+1:0] selected_sub;
            wire [WMAN-1:0] rem_next;
            wire [QRAW-1:0] raw_next;

            _zkf_div_radix4_select #(.WMAN(WMAN)) u_select (
                .den(source_den),
                .rem(source_rem),
                .rem4(selected_rem4),
                .digit(selected_digit),
                .sub(selected_sub)
            );

            _zkf_div_radix4_commit #(.WMAN(WMAN), .QRAW(QRAW)) u_commit (
                .rem4(p_rem4[i_stage]),
                .sub(p_sub[i_stage]),
                .raw(p_raw[i_stage]),
                .digit(p_digit[i_stage]),
                .rem_next(rem_next),
                .raw_next(raw_next)
            );

            always @(posedge clk) begin
                if (rst) begin
                    p_valid[i_stage] <= 1'b0;
                end else begin
                    p_valid[i_stage] <= source_valid;
                end
                p_sign[i_stage]       <= source_sign;
                p_scale[i_stage]      <= source_scale;
                p_force_zero[i_stage] <= source_force_zero;
                p_force_inf[i_stage]  <= source_force_inf;
                p_div0[i_stage]       <= source_div0;
                p_den[i_stage]        <= source_den;
                p_rem4[i_stage]       <= selected_rem4;
                p_raw[i_stage]        <= source_raw;
                p_digit[i_stage]      <= selected_digit;
                p_sub[i_stage]        <= selected_sub;
            end

            // Commit the selected radix-4 digit. Reset only validity; payload registers intentionally free-run.
            always @(posedge clk) begin
                if (rst) begin
                    r_valid[i_stage] <= 1'b0;
                end else begin
                    r_valid[i_stage] <= p_valid[i_stage];
                end
                r_sign[i_stage]       <= p_sign[i_stage];
                r_scale[i_stage]      <= p_scale[i_stage];
                r_force_zero[i_stage] <= p_force_zero[i_stage];
                r_force_inf[i_stage]  <= p_force_inf[i_stage];
                r_div0[i_stage]       <= p_div0[i_stage];
                r_den[i_stage]        <= p_den[i_stage];
                r_rem[i_stage]        <= rem_next;
                r_raw[i_stage]        <= raw_next;
            end
        end
    endgenerate

    assign out_valid   = r_valid[QSTAGES];
    assign sign        = r_sign[QSTAGES];
    assign mag         = {r_raw[QSTAGES], |r_rem[QSTAGES]};
    assign mag_zero    = r_force_zero[QSTAGES];
    assign mag_flog2   = r_raw[QSTAGES][QFRAC] ? MAG_LOG2_HI : MAG_LOG2_LO;
    assign scale       = r_force_inf[QSTAGES] ? FORCE_INF_SCALE : r_scale[QSTAGES];
    assign div0        = r_div0[QSTAGES];
    assign partial_rem = r_rem[QSTAGES];
endmodule


// Select one radix-4 quotient digit by comparing 4*remainder against 1x, 2x, and 3x the denominator.
// The selected subtrahend is registered by the caller before the subtract is committed.
module _zkf_div_radix4_select#(parameter WMAN = 18) (
    input wire [WMAN-1:0] den,
    input wire [WMAN-1:0] rem,

    output wire [WMAN+1:0] rem4,
    output wire      [1:0] digit,
    output wire [WMAN+1:0] sub
);
    localparam WREM4 = WMAN + 2;

    wire [WREM4-1:0] den1 = {{2{1'b0}}, den};
    wire [WREM4-1:0] den2 = {{1{1'b0}}, den, 1'b0};
    wire [WREM4-1:0] den3 = den2 + den1;

    assign rem4  = {rem, 2'b00};
    assign digit = (rem4 >= den3) ? 2'd3 : ((rem4 >= den2) ? 2'd2 : ((rem4 >= den1) ? 2'd1 : 2'd0));
    assign sub   = digit[1] ? (digit[0] ? den3 : den2) : (digit[0] ? den1 : {WREM4{1'b0}});
endmodule


// Commit a previously selected radix-4 digit: subtract the selected multiple and append the two quotient bits.
module _zkf_div_radix4_commit#(parameter WMAN = 18, parameter QRAW = WMAN + 5) (
    input wire [WMAN+1:0] rem4,
    input wire [WMAN+1:0] sub,
    input wire [QRAW-1:0] raw,
    input wire      [1:0] digit,

    output wire [WMAN-1:0] rem_next,
    output wire [QRAW-1:0] raw_next
);
    localparam WREM4 = WMAN + 2;

    wire [WREM4-1:0] rem_full = rem4 - sub;

    assign rem_next = rem_full[WMAN-1:0];
    assign raw_next = {raw[QRAW-3:0], digit};
endmodule

`default_nettype wire
