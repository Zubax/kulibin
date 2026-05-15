/// Streamed Zubax Kulibin float adder.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Pipeline depth: four stages from in_valid to out_valid.

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
    localparam [WEXP-1:0]   EXP_BIAS = {1'b0, {WEXP-1{1'b1}}};

    // Operand decode/classification. Exponent-zero operands are zero regardless of sign/fraction payload.
    wire            a_sign    = a[WFULL-1];
    wire            b_sign    = b[WFULL-1];
    wire            same_sign = ~(a_sign ^ b_sign);
    wire [WEXP-1:0] a_exp     = a[WFULL-2:WFRAC];
    wire [WEXP-1:0] b_exp     = b[WFULL-2:WFRAC];

    wire             a_inf         = &a_exp;
    wire             b_inf         = &b_exp;
    wire             a_finite      = (|a_exp) && !a_inf;
    wire             b_finite      = (|b_exp) && !b_inf;
    wire [WFRAC-1:0] a_fraction    = a[WFRAC-1:0];
    wire [WFRAC-1:0] b_fraction    = b[WFRAC-1:0];
    wire [WMAN-1:0]  a_significand = {1'b1, a_fraction};
    wire [WMAN-1:0]  b_significand = {1'b1, b_fraction};

    // Finite exponent order feeds exponent arithmetic; full magnitude order feeds significand subtraction.
    wire [WEXP-1:0] a_key_exp = a_finite ? a_exp : {WEXP{1'b0}};
    wire [WEXP-1:0] b_key_exp = b_finite ? b_exp : {WEXP{1'b0}};
    wire [WMAN-1:0] a_key_sig = a_finite ? a_significand : {WMAN{1'b0}};
    wire [WMAN-1:0] b_key_sig = b_finite ? b_significand : {WMAN{1'b0}};

    wire a_exp_gt_b_exp = a_key_exp > b_key_exp;
    wire a_exp_eq_b_exp = a_key_exp == b_key_exp;
    wire a_exp_ge_b_exp = a_exp_gt_b_exp || a_exp_eq_b_exp;
    wire a_sig_ge_b_sig;
    wire a_mag_ge_b_mag = a_exp_gt_b_exp || (a_exp_eq_b_exp && a_sig_ge_b_sig);

    _zkf_add_ge #(.W(WMAN)) u_sig_ge (.a(a_key_sig), .b(b_key_sig), .ge(a_sig_ge_b_sig));

    wire  [WEXP-1:0] large_exp = a_exp_ge_b_exp ? a_key_exp : b_key_exp;
    wire  [WEXP-1:0] small_exp = a_exp_ge_b_exp ? b_key_exp : a_key_exp;
    wire  [WMAN-1:0] large_sig = a_mag_ge_b_mag ? a_key_sig : b_key_sig;
    wire  [WMAN-1:0] small_sig = a_mag_ge_b_mag ? b_key_sig : a_key_sig;

    // Stage 0: decoded/classified operands and controls.
    reg                            s0_valid;
    reg                            s0_sign;
    reg                            s0_same_sign;
    reg                            s0_finite_only;
    reg                            s0_force_zero;
    reg                            s0_force_inf;
    reg signed [WEXP_UNBIASED-1:0] s0_exp_unbiased;
    reg                 [WEXP-1:0] s0_exp_diff;
    reg                 [WMAN-1:0] s0_large_sig;
    reg                 [WMAN-1:0] s0_small_sig;

    wire [WEXT-1:0] s0_large_ext = {s0_large_sig, {WGRS{1'b0}}};
    wire [WEXT-1:0] s0_small_ext = {s0_small_sig, {WGRS{1'b0}}};
    wire [WEXT-1:0] s0_small_aligned;

    _zkf_add_align_sticky #(.W(WEXT), .WSHIFT(WSHIFT)) u_align_small (
        .x(s0_small_ext),
        .shamt({{(WSHIFT-WEXP){1'b0}}, s0_exp_diff}),
        .y(s0_small_aligned)
    );

    wire [WRAW-1:0] s0_adder_a     = {1'b0, s0_large_ext};
    wire [WRAW-1:0] s0_adder_b_abs = {1'b0, s0_small_aligned};
    wire [WRAW-1:0] s0_adder_b     = s0_same_sign ? s0_adder_b_abs : ~s0_adder_b_abs;
    wire [WRAW-1:0] s0_raw_result  = s0_adder_a + s0_adder_b + {{(WRAW-1){1'b0}}, !s0_same_sign};

    // Stage 1: registered aligned add/sub result.
    reg                            s1_valid;
    reg                            s1_sign;
    reg                            s1_same_sign;
    reg                            s1_finite_only;
    reg                            s1_force_zero;
    reg                            s1_force_inf;
    reg signed [WEXP_UNBIASED-1:0] s1_exp_unbiased;
    reg                 [WRAW-1:0] s1_raw_result;

    // Same-sign addition never left-normalizes, so a jammed LSB remains sticky. For subtraction, close
    // cancellation only occurs with small exact alignment shifts; far cancellation cannot require a full-width
    // discarded tail, and the compact GRS representation supplies the packer with sufficient rounding state.
    wire s1_add_carry = s1_raw_result[WRAW-1];
    wire signed [WEXP_UNBIASED-1:0] s1_add_exp_unbiased = s1_exp_unbiased + {{(WEXP_UNBIASED-1){1'b0}}, s1_add_carry};
    wire [WMAN-1:0] s1_add_significand = s1_add_carry ? s1_raw_result[WRAW-1 -: WMAN] : s1_raw_result[NORM_TOP -: WMAN];
    wire s1_add_guard  = s1_add_carry ? s1_raw_result[WRAW-WMAN-1] : s1_raw_result[NORM_TOP-WMAN];
    wire s1_add_round  = s1_add_carry ? s1_raw_result[WRAW-WMAN-2] : s1_raw_result[NORM_TOP-WMAN-1];
    wire s1_add_sticky = s1_add_carry ? (|s1_raw_result[WRAW-WMAN-3:0]) : (|s1_raw_result[NORM_TOP-WMAN-2:0]);

    wire                            s1_sub_zero;
    wire signed [WEXP_UNBIASED-1:0] s1_sub_exp_unbiased;
    wire                 [WMAN-1:0] s1_sub_significand;
    wire                            s1_sub_guard;
    wire                            s1_sub_round;
    wire                            s1_sub_sticky;

    _zkf_add_sub_normalize #(.WMAN(WMAN), .WRAW(WRAW), .WINDEX(WINDEX), .WEXP_UNBIASED(WEXP_UNBIASED)) u_sub_norm (
        .x(s1_raw_result),
        .exp_unbiased(s1_exp_unbiased),
        .zero(s1_sub_zero),
        .exp_unbiased_out(s1_sub_exp_unbiased),
        .significand(s1_sub_significand),
        .guard(s1_sub_guard),
        .round(s1_sub_round),
        .sticky(s1_sub_sticky)
    );

    wire s1_finite_zero = s1_same_sign ? (~|s1_raw_result) : s1_sub_zero;

    // Stage 2: registered normalized value for _zkf_pack.
    reg                            s2_valid;
    reg                            s2_sign;
    reg                            s2_force_zero;
    reg                            s2_force_inf;
    reg signed [WEXP_UNBIASED-1:0] s2_exp_unbiased;
    reg                 [WMAN-1:0] s2_significand;
    reg                            s2_guard;
    reg                            s2_round;
    reg                            s2_sticky;

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEXP_UNBIASED)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s2_valid),
        .sign(s2_sign),
        .force_zero(s2_force_zero),
        .force_inf(s2_force_inf),
        .exp_unbiased(s2_exp_unbiased),
        .significand(s2_significand),
        .guard(s2_guard),
        .round(s2_round),
        .sticky(s2_sticky),
        .out_valid(out_valid),
        .y(y)
    );

    // Reset only stream validity. Payload registers intentionally free-run.
    always @(posedge clk) begin
        if (rst) begin
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
        end else begin
            s0_valid <= in_valid;
            s1_valid <= s0_valid;
            s2_valid <= s1_valid;
        end

        // Stage 0 capture: finite operand order, exponent delta, and special-case controls.
        s0_sign <= (a_inf && a_sign) || (!a_inf && b_inf && b_sign) ||
                   (!a_inf && !b_inf && (a_mag_ge_b_mag ? a_sign : b_sign));
        s0_same_sign    <= same_sign;
        s0_finite_only  <= !a_inf && !b_inf;
        s0_force_zero   <= a_inf && b_inf && !same_sign;
        s0_force_inf    <= a_inf || b_inf;
        s0_exp_unbiased <= {{(WEXP_UNBIASED-WEXP){1'b0}}, large_exp} - {{(WEXP_UNBIASED-WEXP){1'b0}}, EXP_BIAS};
        s0_exp_diff     <= large_exp - small_exp;
        s0_large_sig    <= large_sig;
        s0_small_sig    <= small_sig;

        // Stage 1 capture: the single carry-chain computes add or subtract by conditionally inverting the small
        // aligned operand and adding the carry-in.
        s1_sign         <= s0_sign;
        s1_same_sign    <= s0_same_sign;
        s1_finite_only  <= s0_finite_only;
        s1_force_zero   <= s0_force_zero;
        s1_force_inf    <= s0_force_inf;
        s1_exp_unbiased <= s0_exp_unbiased;
        s1_raw_result   <= s0_raw_result;

        // Stage 2 capture: pack-ready finite fields and special-case controls.
        s2_sign         <= s1_sign;
        s2_force_zero   <= s1_force_zero || (s1_finite_only && s1_finite_zero);
        s2_force_inf    <= s1_force_inf;
        s2_exp_unbiased <= s1_same_sign ? s1_add_exp_unbiased : s1_sub_exp_unbiased;
        s2_significand  <= s1_same_sign ? s1_add_significand  : s1_sub_significand;
        s2_guard        <= s1_same_sign ? s1_add_guard        : s1_sub_guard;
        s2_round        <= s1_same_sign ? s1_add_round        : s1_sub_round;
        s2_sticky       <= s1_same_sign ? s1_add_sticky       : s1_sub_sticky;
    end
endmodule


// Compare unsigned values by selecting the highest differing bit.
module _zkf_add_ge #(parameter W = 18) (input wire [W-1:0] a, input wire [W-1:0] b, output wire ge);
    wire [W-1:0] diff = a ^ b;
    wire [W-1:0] a_gt_at;
    genvar i_bit;
    generate
        for (i_bit = 0; i_bit < W; i_bit = i_bit + 1) begin : g_bit
            if (i_bit == W - 1) begin : g_top
                assign a_gt_at[i_bit] = diff[i_bit] && a[i_bit];
            end else begin : g_lower
                assign a_gt_at[i_bit] = diff[i_bit] && a[i_bit] && !(|diff[W-1:i_bit+1]);
            end
        end
    endgenerate
    assign ge = !(|diff) || (|a_gt_at);
endmodule


// Normalize a non-negative subtraction result without a variable left shifter. The highest set bit selects one
// constant-shifted candidate; the selected shift also corrects the common exponent.
module _zkf_add_sub_normalize #(
    parameter WMAN          = 18,
    parameter WRAW          = WMAN + 4,
    parameter WINDEX        = $clog2(WRAW),
    parameter WEXP_UNBIASED = WINDEX + 8
) (
    input  wire                 [WRAW-1:0] x,
    input  wire signed [WEXP_UNBIASED-1:0] exp_unbiased,

    output wire                            zero,
    output wire signed [WEXP_UNBIASED-1:0] exp_unbiased_out,
    output wire                 [WMAN-1:0] significand,
    output wire                            guard,
    output wire                            round,
    output wire                            sticky
);
    localparam WGRS         = 3;
    localparam WNORM        = WMAN + WGRS;
    localparam NORM_TOP_INT = WMAN + 2;

    wire                    [NORM_TOP_INT:0] lead_at;
    wire [((NORM_TOP_INT + 1) *  WNORM)-1:0] norm_candidate;
    wire [((NORM_TOP_INT + 2) *  WNORM)-1:0] norm_stage;
    wire [((NORM_TOP_INT + 1) * WINDEX)-1:0] shift_candidate;
    wire [((NORM_TOP_INT + 2) * WINDEX)-1:0] shift_stage;

    assign norm_stage [0 +: WNORM]  = {WNORM{1'b0}};
    assign shift_stage[0 +: WINDEX] = {WINDEX{1'b0}};

    genvar i_norm;
    generate
        for (i_norm = 0; i_norm <= NORM_TOP_INT; i_norm = i_norm + 1) begin : g_norm
            localparam integer SHIFT = NORM_TOP_INT - i_norm;

            wire [WRAW-1 :0] shifted;
            wire [WNORM-1:0] norm_value;

            assign shifted = x << SHIFT;
            if (i_norm == NORM_TOP_INT) begin : g_top
                assign lead_at[i_norm] = x[i_norm];
            end else begin : g_lower
                assign lead_at[i_norm] = x[i_norm] && !(|x[NORM_TOP_INT:i_norm+1]);
            end
            assign norm_value = { shifted[NORM_TOP_INT -: WMAN],
                                  shifted[NORM_TOP_INT-WMAN],
                                  shifted[NORM_TOP_INT-WMAN-1],
                                 |shifted[NORM_TOP_INT-WMAN-2:0] };
            assign norm_candidate[i_norm * WNORM +: WNORM] =
                norm_value & {WNORM{lead_at[i_norm]}};
            assign shift_candidate[i_norm * WINDEX +: WINDEX] =
                SHIFT[WINDEX-1:0] & {WINDEX{lead_at[i_norm]}};
            assign norm_stage[(i_norm + 1) * WNORM +: WNORM] =
                norm_stage[i_norm * WNORM +: WNORM] | norm_candidate[i_norm * WNORM +: WNORM];
            assign shift_stage[(i_norm + 1) * WINDEX +: WINDEX] =
                shift_stage[i_norm * WINDEX +: WINDEX] | shift_candidate[i_norm * WINDEX +: WINDEX];
        end
    endgenerate

    wire                [WNORM-1:0] norm_out  = norm_stage[(NORM_TOP_INT + 1) * WNORM +: WNORM];
    wire               [WINDEX-1:0] shift_out = shift_stage[(NORM_TOP_INT + 1) * WINDEX +: WINDEX];
    wire signed [WEXP_UNBIASED-1:0] shift_ext = {{(WEXP_UNBIASED-WINDEX){1'b0}}, shift_out};

    assign zero             = ~|lead_at;
    assign exp_unbiased_out = exp_unbiased - shift_ext;
    assign significand      = norm_out[WNORM-1 -: WMAN];
    assign guard            = norm_out[WGRS-1];
    assign round            = norm_out[WGRS-2];
    assign sticky           = norm_out[WGRS-3];
endmodule


// Right-shift x by shamt bit positions while making y[0] sticky.
// y[0] includes the shifted bit and every low bit discarded by the shift.
// Higher shift bits are handled as a sticky-only saturation case before the narrower local barrel.
module _zkf_add_align_sticky #(parameter W = 16, parameter WSHIFT = $clog2(W) + 1) (
    input  wire      [W-1:0] x,
    input  wire [WSHIFT-1:0] shamt,
    output wire      [W-1:0] y
);
    localparam WLOCAL = $clog2(W);

    wire                          shift_ge_width;
    wire [((WLOCAL + 1) * W)-1:0] data_stage;
    wire               [WLOCAL:0] sticky_stage;

    assign data_stage[0 +: W] = x;
    assign sticky_stage[0]    = 1'b0;

    genvar i_stage;
    generate
        if (WSHIFT > WLOCAL) begin : g_saturating_shift
            assign shift_ge_width = |shamt[WSHIFT-1:WLOCAL];
        end else begin : g_no_saturating_shift
            assign shift_ge_width = 1'b0;
        end

        for (i_stage = 0; i_stage < WLOCAL; i_stage = i_stage + 1) begin : g_stage
            localparam integer DIST = 1 << i_stage;

            wire [W-1:0] data_in;
            wire [W-1:0] shifted;
            wire         lost;

            assign data_in = data_stage[i_stage * W +: W];

            if (DIST >= W) begin : g_saturating
                assign shifted = {W{1'b0}};
                assign lost    = |data_in;
            end else begin : g_in_range
                assign shifted = {{DIST{1'b0}}, data_in[W-1:DIST]};
                assign lost    = |data_in[DIST-1:0];
            end

            assign data_stage[(i_stage + 1) * W +: W] = shamt[i_stage] ? shifted : data_in;
            assign sticky_stage[i_stage + 1]          = sticky_stage[i_stage] | (shamt[i_stage] & lost);
        end
    endgenerate

    wire [W-1:0] in_range_y = {data_stage[(WLOCAL * W) + W - 1:(WLOCAL * W) + 1],
                               data_stage[WLOCAL * W] | sticky_stage[WLOCAL]};

    assign y = shift_ge_width ? {{(W-1){1'b0}}, |x} : in_range_y;
endmodule

`default_nettype wire
