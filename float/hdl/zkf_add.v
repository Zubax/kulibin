/// Streamed Zubax Kulibin float adder.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Pipeline depth: two stages from in_valid to out_valid.

`default_nettype none

module zkf_add #(
    parameter WEXP = 6,      // exponent field width
    parameter WMAN = 18      // significand precision including the hidden bit
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,

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
    localparam WGRS          = 3;
    localparam WEXT          = WMAN + WGRS;
    localparam WRAW          = WEXT + 1;
    localparam WINDEX        = $clog2(WRAW);
    localparam WSHIFT        = (WEXP > (WINDEX + 1)) ? WEXP : (WINDEX + 1);
    localparam WEXP_UNBIASED = WEXP + WINDEX + 2;

    localparam [WINDEX-1:0] NORM_TOP = WMAN + 2;

    // Operand decode/classification. Exponent-zero operands are zero regardless of sign/fraction payload.
    wire             a_sign = a[WFULL-1];
    wire             b_sign = b[WFULL-1];
    wire  [WEXP-1:0] a_exp  = a[WFULL-2:WFRAC];
    wire  [WEXP-1:0] b_exp  = b[WFULL-2:WFRAC];
    wire [WFRAC-1:0] a_frac = a[WFRAC-1:0];
    wire [WFRAC-1:0] b_frac = b[WFRAC-1:0];

    wire            a_zero        = ~|a_exp;
    wire            b_zero        = ~|b_exp;
    wire            a_inf         = &a_exp;
    wire            b_inf         = &b_exp;
    wire            a_finite      = !a_zero && !a_inf;
    wire            b_finite      = !b_zero && !b_inf;
    wire            any_inf       = a_inf || b_inf;
    wire            opposite_inf  = a_inf && b_inf && (a_sign != b_sign);
    wire [WMAN-1:0] a_significand = {1'b1, a_frac};
    wire [WMAN-1:0] b_significand = {1'b1, b_frac};

    // Finite magnitude order is determined before alignment from decoded exponent/significand keys. Zeros use a
    // zero significand; infinities are consumed by the special-case controls and omitted from the finite datapath.
    wire  [WEXP-1:0] a_key_exp      = a_finite ? a_exp : {WEXP{1'b0}};
    wire  [WEXP-1:0] b_key_exp      = b_finite ? b_exp : {WEXP{1'b0}};
    wire  [WMAN-1:0] a_key_sig      = a_finite ? a_significand : {WMAN{1'b0}};
    wire  [WMAN-1:0] b_key_sig      = b_finite ? b_significand : {WMAN{1'b0}};
    wire [WFULL-1:0] a_mag_key      = {a_key_exp, a_key_sig};
    wire [WFULL-1:0] b_mag_key      = {b_key_exp, b_key_sig};
    wire             a_mag_ge_b_mag = a_mag_key >= b_mag_key;

    wire            a_exp_ge_b = a_key_exp >= b_key_exp;
    wire [WEXP-1:0] max_exp    = a_exp_ge_b ? a_key_exp : b_key_exp;
    wire [WEXP-1:0] a_exp_diff = max_exp - a_key_exp;
    wire [WEXP-1:0] b_exp_diff = max_exp - b_key_exp;

    wire [WEXT-1:0] a_ext_base = a_finite ? {a_significand, {WGRS{1'b0}}} : {WEXT{1'b0}};
    wire [WEXT-1:0] b_ext_base = b_finite ? {b_significand, {WGRS{1'b0}}} : {WEXT{1'b0}};
    wire [WEXT-1:0] a_aligned;
    wire [WEXT-1:0] b_aligned;

    // Two aligners are retained intentionally for timing: each operand shifts directly by max_exp-exp, avoiding a
    // mux-before-barrel-shifter path. A one-aligner area-optimized variant can be introduced separately if needed.
    _zkf_add_align_sticky #(.W(WEXT), .WSHIFT(WSHIFT)) u_align_a (
        .x(a_ext_base),
        .shamt({{(WSHIFT-WEXP){1'b0}}, a_exp_diff}),
        .y(a_aligned)
    );
    _zkf_add_align_sticky #(.W(WEXT), .WSHIFT(WSHIFT)) u_align_b (
        .x(b_ext_base),
        .shamt({{(WSHIFT-WEXP){1'b0}}, b_exp_diff}),
        .y(b_aligned)
    );

    wire [WEXT-1:0] aligned_large = a_mag_ge_b_mag ? a_aligned : b_aligned;
    wire [WEXT-1:0] aligned_small = a_mag_ge_b_mag ? b_aligned : a_aligned;
    wire [WRAW-1:0] raw_add       = {1'b0, a_aligned}     + {1'b0, b_aligned};
    wire [WRAW-1:0] raw_sub       = {1'b0, aligned_large} - {1'b0, aligned_small};

    // Same-sign addition never left-normalizes, so a jammed LSB remains sticky. For subtraction, close
    // cancellation only occurs with small exact alignment shifts; far cancellation cannot require a full-width
    // discarded tail, and the compact GRS representation supplies the packer with sufficient rounding state.
    wire            add_carry          = raw_add[WRAW-1];
    wire [WMAN-1:0] add_significand_hi = raw_add[WRAW-1 -: WMAN];
    wire            add_guard_hi       = raw_add[WRAW-WMAN-1];
    wire            add_round_hi       = raw_add[WRAW-WMAN-2];
    wire            add_sticky_hi      = |raw_add[WRAW-WMAN-3:0];
    wire [WMAN-1:0] add_significand_lo = raw_add[NORM_TOP -: WMAN];
    wire            add_guard_lo       = raw_add[NORM_TOP-WMAN];
    wire            add_round_lo       = raw_add[NORM_TOP-WMAN-1];
    wire            add_sticky_lo      = |raw_add[NORM_TOP-WMAN-2:0];
    wire [WMAN-1:0] add_significand    = add_carry ? add_significand_hi : add_significand_lo;
    wire            add_guard          = add_carry ? add_guard_hi       : add_guard_lo;
    wire            add_round          = add_carry ? add_round_hi       : add_round_lo;
    wire            add_sticky         = add_carry ? add_sticky_hi      : add_sticky_lo;

    wire              sub_zero;
    wire [WINDEX-1:0] sub_index;
    wire [WINDEX-1:0] sub_shift       = NORM_TOP - sub_index;
    wire   [WRAW-1:0] sub_left        = raw_sub << sub_shift;
    wire   [WMAN-1:0] sub_significand = sub_left[NORM_TOP -: WMAN];
    wire              sub_guard       = sub_left[NORM_TOP-WMAN];
    wire              sub_round       = sub_left[NORM_TOP-WMAN-1];
    wire              sub_sticky      = |sub_left[NORM_TOP-WMAN-2:0];

    _zkf_ilog2_floor #(.W(WRAW), .WINDEX(WINDEX)) u_sub_norm (.x(raw_sub), .zero(sub_zero), .y(sub_index));

    wire same_sign   = a_sign == b_sign;
    wire finite_zero = same_sign ? (~|raw_add) : sub_zero;
    wire finite_sign = same_sign ? a_sign : (a_mag_ge_b_mag ? a_sign : b_sign);

    wire result_inf_sign = a_inf ? a_sign : b_sign;
    wire result_inf      = any_inf && !opposite_inf;
    wire result_zero     = opposite_inf || (!any_inf && finite_zero);
    wire result_sign     = result_inf ? result_inf_sign : finite_sign;

    wire signed [WEXP_UNBIASED-1:0] max_exp_ext      = {{(WEXP_UNBIASED-WEXP){1'b0}}, max_exp};
    wire signed [WEXP_UNBIASED-1:0] bias_ext         = {{(WEXP_UNBIASED-WEXP+1){1'b0}}, {WEXP-1{1'b1}}};
    wire signed [WEXP_UNBIASED-1:0] com_exp_unbiased = max_exp_ext - bias_ext;
    wire signed [WEXP_UNBIASED-1:0] add_exp_unbiased = com_exp_unbiased + {{(WEXP_UNBIASED-1){1'b0}}, add_carry};
    wire signed [WEXP_UNBIASED-1:0] sub_exp_unbiased = com_exp_unbiased - {{(WEXP_UNBIASED-WINDEX){1'b0}}, sub_shift};
    wire signed [WEXP_UNBIASED-1:0] finite_exp_unbiased = same_sign ? add_exp_unbiased : sub_exp_unbiased;
    wire                 [WMAN-1:0] finite_significand  = same_sign ? add_significand  : sub_significand;
    wire                            finite_guard        = same_sign ? add_guard        : sub_guard;
    wire                            finite_round        = same_sign ? add_round        : sub_round;
    wire                            finite_sticky       = same_sign ? add_sticky       : sub_sticky;

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
        s1_force_zero    <= result_zero;
        s1_force_inf     <= result_inf;
        s1_exp_unbiased  <= finite_exp_unbiased;
        s1_significand   <= finite_significand;
        s1_guard         <= finite_guard;
        s1_round         <= finite_round;
        s1_sticky        <= finite_sticky;
    end
endmodule


// Right-shift x by shamt bit positions while making y[0] sticky.
// y[0] includes the shifted bit and every low bit discarded by the shift.
// The shift amount (shamt) is the exponent-difference alignment shift; W_EXT is W represented at WSHIFT width.
module _zkf_add_align_sticky #(parameter W = 16, parameter WSHIFT = $clog2(W) + 1) (
    input  wire      [W-1:0] x,
    input  wire [WSHIFT-1:0] shamt,
    output wire      [W-1:0] y
);
    localparam [WSHIFT-1:0] W_EXT = W;  // cast width

    wire              shift_ge_width = shamt >= W_EXT;
    wire      [W-1:0] shifted        = shift_ge_width ? {W{1'b0}} : (x >> shamt);
    wire [WSHIFT-1:0] lost_shift     = W_EXT - shamt;
    wire      [W-1:0] lost_window    = x << lost_shift;
    wire              lost           = (|shamt) && (shift_ge_width ? (|x) : (|lost_window));

    assign y = shifted | {{(W-1){1'b0}}, lost};
endmodule

`default_nettype wire
