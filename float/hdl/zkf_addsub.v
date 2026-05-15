/// Streamed Zubax Kulibin float adder/subtractor.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Pipeline depth: two stages from in_valid to out_valid.

`default_nettype none

module zkf_addsub #(
    parameter WEXP = 6,      // exponent field width
    parameter WMAN = 18      // significand precision including the hidden bit
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,
    input wire                 op_sub, // if op_sub: y=a-b; else: y=a+b

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y
);
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wman
            _zkf_invalid_wexp_or_wman u_invalid();
        end
    endgenerate

    localparam WFRAC          = WMAN - 1;
    localparam WFULL          = WEXP + WMAN;
    localparam WTAIL          = WMAN + 3;
    localparam WMAG           = WMAN + WTAIL + 1;
    localparam WINDEX         = (WMAG <= 2) ? 1 : $clog2(WMAG);
    localparam WSHIFT         = (WEXP > (WINDEX + 1)) ? WEXP : (WINDEX + 1);
    localparam WEXP_UNBIASED  = WEXP + WINDEX + 2;
    localparam SCALE_OFFSET   = WFRAC + WTAIL;

    localparam   [WEXP-1:0] EXP_BIAS = {1'b0, {WEXP-1{1'b1}}};
    localparam   [WEXP-1:0] EXP_INF  = {WEXP{1'b1}};
    localparam [WINDEX-1:0] NORM_TOP = WMAG - 1;

    localparam signed [WEXP_UNBIASED-1:0] SCALE_OFFSET_EXT = SCALE_OFFSET;

    // Operand decode/classification. Exponent-zero operands are zero regardless of sign/fraction payload.
    wire             a_sign     = a[WFULL-1];
    wire             b_sign     = b[WFULL-1];
    wire             b_eff_sign = b_sign ^ op_sub;
    wire  [WEXP-1:0] a_exp      = a[WFULL-2:WFRAC];
    wire  [WEXP-1:0] b_exp      = b[WFULL-2:WFRAC];
    wire [WFRAC-1:0] a_frac     = a[WFRAC-1:0];
    wire [WFRAC-1:0] b_frac     = b[WFRAC-1:0];

    wire            a_zero        = a_exp == {WEXP{1'b0}};
    wire            b_zero        = b_exp == {WEXP{1'b0}};
    wire            a_inf         = a_exp == EXP_INF;
    wire            b_inf         = b_exp == EXP_INF;
    wire            any_inf       = a_inf || b_inf;
    wire            opposite_inf  = a_inf && b_inf && (a_sign != b_eff_sign);
    wire [WMAN-1:0] a_significand = {1'b1, a_frac};
    wire [WMAN-1:0] b_significand = {1'b1, b_frac};

    // Finite add/subtract datapath. The low WTAIL bits provide room for GRS and cancellation.
    wire [WMAG-1:0] a_mag_base = a_zero ? {WMAG{1'b0}} : {1'b0, a_significand, {WTAIL{1'b0}}};
    wire [WMAG-1:0] b_mag_base = b_zero ? {WMAG{1'b0}} : {1'b0, b_significand, {WTAIL{1'b0}}};

    wire            a_exp_ge_b = a_exp >= b_exp;
    wire [WEXP-1:0] max_exp    = a_exp_ge_b ? a_exp : b_exp;
    wire [WEXP-1:0] a_exp_diff = max_exp - a_exp;
    wire [WEXP-1:0] b_exp_diff = max_exp - b_exp;

    wire [WMAG-1:0] a_mag_aligned;
    wire [WMAG-1:0] b_mag_aligned;

    _zkf_addsub_align_sticky #(.W(WMAG), .WSHIFT(WSHIFT)) u_align_a (
        .x(a_mag_base),
        .shamt({{(WSHIFT-WEXP){1'b0}}, a_exp_diff}),
        .y(a_mag_aligned)
    );
    _zkf_addsub_align_sticky #(.W(WMAG), .WSHIFT(WSHIFT)) u_align_b (
        .x(b_mag_base),
        .shamt({{(WSHIFT-WEXP){1'b0}}, b_exp_diff}),
        .y(b_mag_aligned)
    );

    wire            same_sign       = a_sign == b_eff_sign;
    wire            a_mag_ge_b_mag  = a_mag_aligned >= b_mag_aligned;
    wire [WMAG-1:0] finite_mag_sum  = a_mag_aligned + b_mag_aligned;
    wire [WMAG-1:0] finite_mag_diff = a_mag_ge_b_mag ? (a_mag_aligned - b_mag_aligned) :
                                                       (b_mag_aligned - a_mag_aligned);
    wire [WMAG-1:0] finite_mag      = same_sign ? finite_mag_sum : finite_mag_diff;
    wire            finite_zero     = finite_mag == {WMAG{1'b0}};
    wire            finite_sign     = same_sign ? a_sign : (a_mag_ge_b_mag ? a_sign : b_eff_sign);
    wire            result_inf_sign = a_inf ? a_sign : b_eff_sign;
    wire            result_inf      = any_inf && !opposite_inf;
    wire            result_zero     = opposite_inf || (!any_inf && finite_zero);
    wire            result_sign     = result_inf ? result_inf_sign : finite_sign;

    wire                  norm_zero;
    wire [WINDEX-1:0]     norm_index;
    wire [WINDEX-1:0]     norm_shift         = NORM_TOP - norm_index;
    wire [WMAG-1:0]       norm_left          = finite_mag << norm_shift;
    wire [WMAN-1:0]       finite_significand = norm_left[WMAG-1 -: WMAN];
    wire                  finite_guard       = norm_left[WMAG-WMAN-1];
    wire                  finite_round       = norm_left[WMAG-WMAN-2];
    wire                  finite_sticky      = |norm_left[WMAG-WMAN-3:0];

    _zkf_ilog2_floor #(.W(WMAG), .WINDEX(WINDEX)) u_norm (.x(finite_mag), .zero(norm_zero), .y(norm_index));

    wire signed [WEXP_UNBIASED-1:0] max_exp_ext  = {{(WEXP_UNBIASED-WEXP){1'b0}}, max_exp};
    wire signed [WEXP_UNBIASED-1:0] bias_ext     = {{(WEXP_UNBIASED-WEXP){1'b0}}, EXP_BIAS};
    wire signed [WEXP_UNBIASED-1:0] norm_ext     = {{(WEXP_UNBIASED-WINDEX){1'b0}}, norm_index};
    wire signed [WEXP_UNBIASED-1:0] exp_unbiased = max_exp_ext - bias_ext + norm_ext - SCALE_OFFSET_EXT;

    // Stage 1: registered normalized value for _zkf_pack.
    reg                            s1_valid;
    reg                            s1_sign;
    reg                            s1_force_zero;
    reg                            s1_force_inf;
    reg signed [WEXP_UNBIASED-1:0] s1_exp_unbiased;
    reg                 [WMAN-1:0] s1_significand;
    reg                            s1_guard;
    reg                            s1_round;
    reg                            s1_sticky;

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEXP_UNBIASED)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s1_valid),
        .sign(s1_sign),
        .force_zero(s1_force_zero),
        .force_inf(s1_force_inf),
        .exp_unbiased(s1_exp_unbiased),
        .significand(s1_significand),
        .guard(s1_guard),
        .round(s1_round),
        .sticky(s1_sticky),
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

        s1_sign          <= result_sign;
        s1_force_zero    <= result_zero || norm_zero;
        s1_force_inf     <= result_inf;
        s1_exp_unbiased  <= exp_unbiased;
        s1_significand   <= finite_significand;
        s1_guard         <= finite_guard;
        s1_round         <= finite_round;
        s1_sticky        <= finite_sticky;
    end
endmodule


// Right-shift x by shamt bit positions while making y[0] sticky.
// y[0] includes the shifted bit and every low bit discarded by the shift.
// The shift amount (shamt) is the exponent-difference alignment shift; W_EXT is W represented at WSHIFT width.
module _zkf_addsub_align_sticky #(parameter W = 16, parameter WSHIFT = $clog2(W) + 1) (
    input  wire      [W-1:0] x,
    input  wire [WSHIFT-1:0] shamt,
    output wire      [W-1:0] y
);
    localparam [WSHIFT-1:0] W_EXT = W;

    wire              shift_ge_width = shamt >= W_EXT;
    wire      [W-1:0] shifted        = shift_ge_width ? {W{1'b0}} : (x >> shamt);
    wire [WSHIFT-1:0] lost_shift     = W_EXT - shamt;
    wire      [W-1:0] lost_window    = x << lost_shift;
    wire              lost           = (shamt != {WSHIFT{1'b0}}) && (shift_ge_width ? (|x) : (|lost_window));

    assign y = shifted | {{(W-1){1'b0}}, lost};
endmodule

`default_nettype wire
