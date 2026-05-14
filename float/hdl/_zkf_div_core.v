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
/// Pipeline depth: WMAN+5+((WMAN+4)%2) stages from in_valid to out_valid:
/// one preparation stage plus two stages per radix-4 quotient digit. Throughput is one sample per cycle.

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
    localparam WREM4   = WMAN + 2;

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

    wire            a_zero        = a_exp == {WEXP{1'b0}};
    wire            b_zero        = b_exp == {WEXP{1'b0}};
    wire            a_inf         = a_exp == EXP_INF;
    wire            b_inf         = b_exp == EXP_INF;
    wire            result_zero   = a_zero || b_inf;
    wire            result_inf    = !a_zero && !b_inf && (b_zero || a_inf);
    wire            result_sign   = b_zero ? a_sign : (a_sign ^ b_sign);
    wire [WMAN-1:0] a_significand = {1'b1, a_frac};
    wire [WMAN-1:0] b_significand = {1'b1, b_frac};
    wire            initial_bit   = a_significand >= b_significand;
    wire [WMAN-1:0] initial_rem   = initial_bit ? (a_significand - b_significand) : a_significand;

    wire signed [WSCALE-1:0] a_exp_ext     = {{(WSCALE-WEXP){1'b0}}, a_exp};
    wire signed [WSCALE-1:0] b_exp_ext     = {{(WSCALE-WEXP){1'b0}}, b_exp};
    wire signed [WSCALE-1:0] decoded_scale = a_exp_ext - b_exp_ext - QFRAC_PLUS_ONE;

    reg                     r_valid      [0:QSTAGES];
    reg                     r_sign       [0:QSTAGES];
    reg signed [WSCALE-1:0] r_scale      [0:QSTAGES];
    reg                     r_force_zero [0:QSTAGES];
    reg                     r_force_inf  [0:QSTAGES];
    reg                     r_div0       [0:QSTAGES];
    reg          [WMAN-1:0] r_den        [0:QSTAGES];
    reg          [WMAN-1:0] r_rem        [0:QSTAGES];
    reg          [QRAW-1:0] r_raw        [0:QSTAGES];

    reg                     p_valid      [0:QSTAGES];
    reg                     p_sign       [0:QSTAGES];
    reg signed [WSCALE-1:0] p_scale      [0:QSTAGES];
    reg                     p_force_zero [0:QSTAGES];
    reg                     p_force_inf  [0:QSTAGES];
    reg                     p_div0       [0:QSTAGES];
    reg          [WMAN-1:0] p_den        [0:QSTAGES];
    reg         [WREM4-1:0] p_rem4       [0:QSTAGES];
    reg          [QRAW-1:0] p_raw        [0:QSTAGES];
    reg               [1:0] p_digit      [0:QSTAGES];
    reg         [WREM4-1:0] p_sub        [0:QSTAGES];

    always @(posedge clk) begin
        if (rst) begin
            r_valid[0] <= 1'b0;
        end else begin
            r_valid[0] <= in_valid;
        end
        r_sign[0]       <= result_sign;
        r_scale[0]      <= decoded_scale;
        r_force_zero[0] <= result_zero;
        r_force_inf[0]  <= result_inf;
        r_div0[0]       <= b_zero;
        r_den[0]        <= b_significand;
        r_rem[0]        <= initial_rem;
        r_raw[0]        <= {{QFRAC{1'b0}}, initial_bit};
    end

    genvar i_stage;
    generate
        for (i_stage = 1; i_stage <= QSTAGES; i_stage = i_stage + 1) begin : g_stage
            wire [WREM4-1:0] rem4  = {r_rem[i_stage-1], 2'b00};
            wire [WREM4-1:0] den1  = {{2{1'b0}}, r_den[i_stage-1]};
            wire [WREM4-1:0] den2  = {{1{1'b0}}, r_den[i_stage-1], 1'b0};
            wire [WREM4-1:0] den3  = den2 + den1;
            wire       [1:0] digit = (rem4 >= den3) ? 2'd3 : ((rem4 >= den2) ? 2'd2 : ((rem4 >= den1) ? 2'd1 : 2'd0));
            wire [WREM4-1:0] sub   = digit[1] ? (digit[0] ? den3 : den2) : (digit[0] ? den1 : {WREM4{1'b0}});
            wire [WREM4-1:0] rem_next = p_rem4[i_stage] - p_sub[i_stage];

            always @(posedge clk) begin
                if (rst) begin
                    p_valid[i_stage] <= 1'b0;
                end else begin
                    p_valid[i_stage] <= r_valid[i_stage-1];
                end
                p_sign[i_stage]       <= r_sign[i_stage-1];
                p_scale[i_stage]      <= r_scale[i_stage-1];
                p_force_zero[i_stage] <= r_force_zero[i_stage-1];
                p_force_inf[i_stage]  <= r_force_inf[i_stage-1];
                p_div0[i_stage]       <= r_div0[i_stage-1];
                p_den[i_stage]        <= r_den[i_stage-1];
                p_rem4[i_stage]       <= rem4;
                p_raw[i_stage]        <= r_raw[i_stage-1];
                p_digit[i_stage]      <= digit;
                p_sub[i_stage]        <= sub;
            end

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
                r_rem[i_stage]        <= rem_next[WMAN-1:0];
                r_raw[i_stage]        <= {p_raw[i_stage][QRAW-3:0], p_digit[i_stage]};
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

`default_nettype wire
