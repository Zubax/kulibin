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
/// Pipeline depth: 1+((WMAN+4+((WMAN+4)%2))/2) stages from in_valid to out_valid:
/// one preparation stage plus one stage per radix-4 quotient digit. Throughput is one sample per cycle.

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
    localparam QTRI    = (QSTAGES + 1) * (QSTAGES + 1);

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
    wire             initial_bit  = a_significand >= b_significand;
    wire  [WMAN-1:0] initial_rem  = initial_bit ? (a_significand - b_significand) : a_significand;
    wire [WREM4-1:0] initial_den3 = {1'b0, b_significand, 1'b0} + {2'b00, b_significand};  // x3

    // The raw quotient magnitude is scaled as floor((sig_a / sig_b) * 2^QFRAC), plus sticky.
    // _zkf_pack later adds floor(log2(mag)), so the base scale subtracts QFRAC+1.
    wire signed [WSCALE-1:0] a_exp_ext     = {{(WSCALE-WEXP){1'b0}}, a_exp};
    wire signed [WSCALE-1:0] b_exp_ext     = {{(WSCALE-WEXP){1'b0}}, b_exp};
    wire signed [WSCALE-1:0] decoded_scale = a_exp_ext - b_exp_ext - QFRAC_PLUS_ONE;

    // Stage zero keeps input decode/classification and the first radix-4 digit off the same path. It also
    // precomputes 3*den once; later stages only form cheap 1*den and 2*den wires locally.
    // Each later pipeline stage resolves one radix-4 quotient digit. The quotient prefix is stored in a
    // triangular chain: stage i holds only the 1+2*i bits known by that point, not a full QRAW-wide word.
    reg                     r_valid      [0:QSTAGES];
    reg                     r_sign       [0:QSTAGES];
    reg signed [WSCALE-1:0] r_scale      [0:QSTAGES];
    reg                     r_force_zero [0:QSTAGES];
    reg                     r_force_inf  [0:QSTAGES];
    reg                     r_div0       [0:QSTAGES];
    reg          [WMAN-1:0] r_den        [0:QSTAGES];
    reg         [WREM4-1:0] r_den3       [0:QSTAGES];
    reg          [WMAN-1:0] r_rem        [0:QSTAGES];
    reg                     r_raw0;

    wire [QTRI-1:0] raw_tri;
    wire [QRAW-1:0] final_raw = raw_tri[(QSTAGES * QSTAGES) +: QRAW];

    assign raw_tri[0] = r_raw0;

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
        r_den3[0]       <= initial_den3;
        r_rem[0]        <= initial_rem;
        r_raw0          <= initial_bit;
    end

    genvar i_stage;
    generate
        for (i_stage = 1; i_stage <= QSTAGES; i_stage = i_stage + 1) begin : g_stage
            localparam WIN     = (2 * i_stage) - 1;
            localparam WOUT    = WIN + 2;
            localparam IN_OFF  = (i_stage - 1) * (i_stage - 1);
            localparam OUT_OFF = i_stage * i_stage;

            wire [WMAN-1:0] rem_next;
            wire      [1:0] digit;

            _zkf_div_radix4_step #(.WMAN(WMAN)) u_step (
                .den(r_den[i_stage-1]),
                .den3(r_den3[i_stage-1]),
                .rem(r_rem[i_stage-1]),
                .rem_next(rem_next),
                .digit(digit)
            );
            _zkf_div_raw_stage #(.WIN(WIN)) u_raw (
                .clk(clk),
                .raw_prefix(raw_tri[IN_OFF +: WIN]),
                .digit(digit),
                .raw_next(raw_tri[OUT_OFF +: WOUT])
            );

            // Reset only validity; payload registers intentionally free-run.
            always @(posedge clk) begin
                if (rst) begin
                    r_valid[i_stage] <= 1'b0;
                end else begin
                    r_valid[i_stage] <= r_valid[i_stage-1];
                end
                r_sign[i_stage]       <= r_sign[i_stage-1];
                r_scale[i_stage]      <= r_scale[i_stage-1];
                r_force_zero[i_stage] <= r_force_zero[i_stage-1];
                r_force_inf[i_stage]  <= r_force_inf[i_stage-1];
                r_div0[i_stage]       <= r_div0[i_stage-1];
                r_den[i_stage]        <= r_den[i_stage-1];
                r_den3[i_stage]       <= r_den3[i_stage-1];
                r_rem[i_stage]        <= rem_next;
            end
        end
    endgenerate

    assign out_valid   = r_valid[QSTAGES];
    assign sign        = r_sign[QSTAGES];
    assign mag         = {final_raw, |r_rem[QSTAGES]};
    assign mag_zero    = r_force_zero[QSTAGES];
    assign mag_flog2   = final_raw[QFRAC] ? MAG_LOG2_HI : MAG_LOG2_LO;
    assign scale       = r_force_inf[QSTAGES] ? FORCE_INF_SCALE : r_scale[QSTAGES];
    assign div0        = r_div0[QSTAGES];
    assign partial_rem = r_rem[QSTAGES];
endmodule


// Register one more radix-4 quotient digit into the narrow prefix known at this stage.
module _zkf_div_raw_stage#(parameter WIN = 1) (
    input wire           clk,
    input wire [WIN-1:0] raw_prefix,
    input wire     [1:0] digit,
    output reg [WIN+1:0] raw_next
);
    always @(posedge clk) begin
        raw_next <= {raw_prefix, digit};
    end
endmodule


// Resolve one radix-4 quotient digit using parallel candidate subtracts.
module _zkf_div_radix4_step#(parameter WMAN = 18) (
    input wire [WMAN-1:0] den,
    input wire [WMAN+1:0] den3,
    input wire [WMAN-1:0] rem,

    output wire [WMAN-1:0] rem_next,
    output wire      [1:0] digit
);
    localparam WREM4 = WMAN + 2;
    localparam WDIFF = WREM4 + 1;

    wire [WREM4-1:0] den1 = {2'b00, den};
    wire [WREM4-1:0] den2 = {1'b0, den, 1'b0};
    wire [WREM4-1:0] rem4 = {rem, 2'b00};

    wire [WDIFF-1:0] diff1 = {1'b0, rem4} - {1'b0, den1};
    wire [WDIFF-1:0] diff2 = {1'b0, rem4} - {1'b0, den2};
    wire [WDIFF-1:0] diff3 = {1'b0, rem4} - {1'b0, den3};
    wire             ge1   = !diff1[WREM4];
    wire             ge2   = !diff2[WREM4];
    wire             ge3   = !diff3[WREM4];

    assign digit[1] = ge2;
    assign digit[0] = ge3 || (ge1 && !ge2);
    assign rem_next = ge3 ? diff3[WMAN-1:0] :
                      ge2 ? diff2[WMAN-1:0] :
                      ge1 ? diff1[WMAN-1:0] :
                            rem4[WMAN-1:0];
endmodule

`default_nettype wire
