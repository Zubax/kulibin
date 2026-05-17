/// Streamed Zubax Kulibin float adder.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Pipeline depth: five stages from in_valid to out_valid.

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

    // Note of caution: merely replacing a named net with its expression at place-of-use may drastically affect
    // the synthesis outcome even though the circuit topology remains unchanged. All synthesis tools are unreliable.
    localparam WFRAC         = WMAN - 1;
    localparam WFULL         = WEXP + WMAN;
    localparam WGRS          = 3;
    localparam WEXT          = WMAN + WGRS;
    localparam WRAW          = WEXT + 1;
    localparam WINDEX        = $clog2(WRAW);
    localparam WSHIFT        = (WEXP > (WINDEX + 1)) ? WEXP : (WINDEX + 1);
    localparam WEXP_SIGNED   = WEXP + 1;
    localparam WSHIFT_SIGNED = WINDEX + 2;
    localparam WEXP_UNBIASED = (WEXP_SIGNED > WSHIFT_SIGNED) ? WEXP_SIGNED : WSHIFT_SIGNED;

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

    wire ordered_exp_sign  = a_exp_ge_b_exp ? a_sign : b_sign;
    wire equal_finite_sign = same_sign ? a_sign : (a_mag_ge_b_mag ? a_sign : b_sign);
    wire inf_sign          = (a_inf & a_sign) | (b_inf & b_sign);

    wire [WEXP-1:0] large_exp     = a_exp_ge_b_exp ? a_key_exp : b_key_exp;
    wire [WEXP-1:0] small_exp     = a_exp_ge_b_exp ? b_key_exp : a_key_exp;
    wire [WMAN-1:0] large_sig_exp = a_exp_ge_b_exp ? a_key_sig : b_key_sig;
    wire [WMAN-1:0] small_sig_exp = a_exp_ge_b_exp ? b_key_sig : a_key_sig;

    // Stage 0: decoded/classified operands, exponent order, and full-magnitude order.
    reg                            s0_valid;
    reg                            s0_ordered_exp_sign;
    reg                            s0_equal_finite_sign;
    reg                            s0_inf_sign;
    reg                            s0_same_sign;
    reg                            s0_force_zero;
    reg                            s0_force_inf;
    reg                            s0_exp_eq;
    reg                            s0_a_mag_ge_b_mag;
    reg signed [WEXP_UNBIASED-1:0] s0_exp_unbiased;
    reg                 [WEXP-1:0] s0_exp_diff;
    reg                 [WMAN-1:0] s0_large_sig_exp;
    reg                 [WMAN-1:0] s0_small_sig_exp;

    wire [WEXT-1:0] s0_small_aligned;

    _zkf_add_align_sticky #(.W(WEXT), .WSHIFT(WSHIFT)) u_align_small (
        .x({s0_small_sig_exp, {WGRS{1'b0}}}),
        .shamt({{(WSHIFT-WEXP){1'b0}}, s0_exp_diff}),
        .y(s0_small_aligned)
    );

    // Stage 1: registered aligned operands.
    reg                            s1_valid;
    reg                            s1_ordered_exp_sign;
    reg                            s1_equal_finite_sign;
    reg                            s1_inf_sign;
    reg                            s1_same_sign;
    reg                            s1_force_zero;
    reg                            s1_force_inf;
    reg                            s1_exp_eq;
    reg                            s1_a_mag_ge_b_mag;
    reg signed [WEXP_UNBIASED-1:0] s1_exp_unbiased;
    reg                 [WEXT-1:0] s1_large_ext_exp;
    reg                 [WEXT-1:0] s1_small_aligned;

    wire            s1_swap_equal  = s1_exp_eq && !s1_a_mag_ge_b_mag;
    wire [WRAW-1:0] s1_adder_a     = {1'b0, s1_swap_equal ? s1_small_aligned : s1_large_ext_exp};
    wire [WRAW-1:0] s1_adder_b_abs = {1'b0, s1_swap_equal ? s1_large_ext_exp : s1_small_aligned};
    wire [WRAW-1:0] s1_adder_b     = s1_same_sign ? s1_adder_b_abs : ~s1_adder_b_abs;
    wire [WRAW-1:0] s1_raw_result  = s1_adder_a + s1_adder_b + {{(WRAW-1){1'b0}}, !s1_same_sign};
    wire            s1_finite_sign = s1_exp_eq    ? s1_equal_finite_sign : s1_ordered_exp_sign;
    wire            s1_result_sign = s1_force_inf ? s1_inf_sign          : s1_finite_sign;

    // Stage 2: registered raw add/sub result.
    reg                            s2_valid;
    reg                            s2_sign;
    reg                            s2_same_sign;
    reg                            s2_force_zero;
    reg                            s2_force_inf;
    reg signed [WEXP_UNBIASED-1:0] s2_exp_unbiased;
    reg                 [WRAW-1:0] s2_raw_result;

    // Same-sign addition never left-normalizes, so a jammed LSB remains sticky. For subtraction, close
    // cancellation only occurs with small exact alignment shifts; far cancellation cannot require a full-width
    // discarded tail, and the compact GRS representation supplies the packer with sufficient rounding state.
    wire                            s2_add_carry        = s2_raw_result[WRAW-1];
    wire signed [WEXP_UNBIASED-1:0] s2_add_exp_unbiased = s2_exp_unbiased + {{(WEXP_UNBIASED-1){1'b0}}, s2_add_carry};
    wire [WMAN-1:0] s2_add_significand = s2_add_carry ? s2_raw_result[WRAW-1 -: WMAN] : s2_raw_result[NORM_TOP -: WMAN];
    wire s2_add_guard  = s2_add_carry ?   s2_raw_result[WRAW-WMAN-1]    :   s2_raw_result[NORM_TOP-WMAN];
    wire s2_add_round  = s2_add_carry ?   s2_raw_result[WRAW-WMAN-2]    :   s2_raw_result[NORM_TOP-WMAN-1];
    wire s2_add_sticky = s2_add_carry ? (|s2_raw_result[WRAW-WMAN-3:0]) : (|s2_raw_result[NORM_TOP-WMAN-2:0]);

    wire                            s2_sub_zero;
    wire               [WINDEX-1:0] s2_sub_shift;
    wire signed [WEXP_UNBIASED-1:0] s2_sub_shift_ext    = {{(WEXP_UNBIASED-WINDEX){1'b0}}, s2_sub_shift};
    wire signed [WEXP_UNBIASED-1:0] s2_sub_exp_unbiased = s2_exp_unbiased - s2_sub_shift_ext;

    _zkf_add_sub_shift_count #(.WMAN(WMAN), .WRAW(WRAW), .WINDEX(WINDEX)) u_sub_shift_count (
        .x(s2_raw_result),
        .zero(s2_sub_zero),
        .shamt(s2_sub_shift)
    );

    wire signed [WEXP_UNBIASED-1:0] s2_pack_exp_unbiased = s2_same_sign ? s2_add_exp_unbiased : s2_sub_exp_unbiased;

    // Stage 3: registered add normalization and subtraction shift count.
    reg                            s3_valid;
    reg                            s3_sign;
    reg                            s3_same_sign;
    reg                            s3_force_zero;
    reg                            s3_force_inf;
    reg                 [WEXT-1:0] s3_raw_result;
    reg signed [WEXP_UNBIASED-1:0] s3_pack_exp_unbiased;
    reg                 [WMAN-1:0] s3_add_significand;
    reg                            s3_add_guard;
    reg                            s3_add_round;
    reg                            s3_add_sticky;
    reg                            s3_sub_zero;
    reg               [WINDEX-1:0] s3_sub_shift;

    wire [WMAN-1:0] s3_sub_significand;
    wire            s3_sub_guard;
    wire            s3_sub_round;
    wire            s3_sub_sticky;

    _zkf_add_sub_shift_apply #(.WMAN(WMAN), .WINDEX(WINDEX)) u_sub_shift (
        .x(s3_raw_result),
        .shamt(s3_sub_shift),
        .significand(s3_sub_significand),
        .guard(s3_sub_guard),
        .round(s3_sub_round),
        .sticky(s3_sub_sticky)
    );

    wire s3_finite_zero = s3_same_sign ? (~|{s3_add_significand, s3_add_guard, s3_add_round, s3_add_sticky})
                                       : s3_sub_zero;
    wire            s3_pack_force_zero  = s3_force_zero || (!s3_force_inf && s3_finite_zero);
    wire [WMAN-1:0] s3_pack_significand = s3_same_sign ? s3_add_significand  : s3_sub_significand;
    wire            s3_pack_guard       = s3_same_sign ? s3_add_guard        : s3_sub_guard;
    wire            s3_pack_round       = s3_same_sign ? s3_add_round        : s3_sub_round;
    wire            s3_pack_sticky      = s3_same_sign ? s3_add_sticky       : s3_sub_sticky;

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEXP_UNBIASED)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s3_valid),
        .sign(s3_sign),
        .force_zero(s3_pack_force_zero),
        .force_inf(s3_force_inf),
        .exp_unbiased(s3_pack_exp_unbiased),
        .significand(s3_pack_significand),
        .guard(s3_pack_guard),
        .round(s3_pack_round),
        .sticky(s3_pack_sticky),
        .out_valid(out_valid),
        .y(y)
    );

    // Reset only stream validity. Payload registers intentionally free-run.
    always @(posedge clk) begin
        if (rst) begin
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
        end else begin
            s0_valid <= in_valid;
            s1_valid <= s0_valid;
            s2_valid <= s1_valid;
            s3_valid <= s2_valid;
        end

        // Stage 0 capture: finite operand order, exponent delta, and special-case controls.
        s0_ordered_exp_sign  <= ordered_exp_sign;
        s0_equal_finite_sign <= equal_finite_sign;
        s0_inf_sign          <= inf_sign;
        s0_same_sign         <= same_sign;
        s0_force_zero        <= a_inf && b_inf && !same_sign;
        s0_force_inf         <= a_inf || b_inf;
        s0_exp_eq            <= a_exp_eq_b_exp;
        s0_a_mag_ge_b_mag    <= a_mag_ge_b_mag;
        s0_exp_unbiased      <= {{(WEXP_UNBIASED-WEXP){1'b0}}, large_exp} - {{(WEXP_UNBIASED-WEXP){1'b0}}, EXP_BIAS};
        s0_exp_diff          <= large_exp - small_exp;
        s0_large_sig_exp     <= large_sig_exp;
        s0_small_sig_exp     <= small_sig_exp;

        // Stage 1 capture: aligned operands. The add/sub carry-chain is in the next stage.
        s1_ordered_exp_sign  <= s0_ordered_exp_sign;
        s1_equal_finite_sign <= s0_equal_finite_sign;
        s1_inf_sign          <= s0_inf_sign;
        s1_same_sign         <= s0_same_sign;
        s1_force_zero        <= s0_force_zero;
        s1_force_inf         <= s0_force_inf;
        s1_exp_eq            <= s0_exp_eq;
        s1_a_mag_ge_b_mag    <= s0_a_mag_ge_b_mag;
        s1_exp_unbiased      <= s0_exp_unbiased;
        s1_large_ext_exp     <= {s0_large_sig_exp, {WGRS{1'b0}}};
        s1_small_aligned     <= s0_small_aligned;

        // Stage 2 capture: the single carry-chain computes add or subtract by conditionally inverting the small
        // aligned operand and adding the carry-in.
        s2_sign              <= s1_result_sign;
        s2_same_sign         <= s1_same_sign;
        s2_force_zero        <= s1_force_zero;
        s2_force_inf         <= s1_force_inf;
        s2_exp_unbiased      <= s1_exp_unbiased;
        s2_raw_result        <= s1_raw_result;

        // Stage 3 capture: add-path normalization and subtract-path shift metadata.
        s3_sign              <= s2_sign;
        s3_same_sign         <= s2_same_sign;
        s3_force_zero        <= s2_force_zero;
        s3_force_inf         <= s2_force_inf;
        s3_raw_result        <= s2_raw_result[WEXT-1:0];
        s3_pack_exp_unbiased <= s2_pack_exp_unbiased;
        s3_add_significand   <= s2_add_significand;
        s3_add_guard         <= s2_add_guard;
        s3_add_round         <= s2_add_round;
        s3_add_sticky        <= s2_add_sticky;
        s3_sub_zero          <= s2_sub_zero;
        s3_sub_shift         <= s2_sub_shift;
    end
endmodule


// Compare unsigned values through an explicit carry-chain-friendly subtraction; enables much better timings than
// the ordinary comparison operator. Related:
// https://stackoverflow.com/questions/60844496/does-subtraction-need-less-resource-than-comparison-symbol-in-verilog
module _zkf_add_ge #(parameter W = 18) (input wire [W-1:0] a, input wire [W-1:0] b, output wire ge);
    wire [W:0] diff = {1'b0, a} - {1'b0, b};
    assign ge = !diff[W];
endmodule


// Find the left shift needed to normalize a non-negative subtraction result.
module _zkf_add_sub_shift_count #(parameter WMAN = 18, parameter WRAW = WMAN + 4, parameter WINDEX = $clog2(WRAW)) (
    input  wire   [WRAW-1:0] x,
    output wire              zero,
    output wire [WINDEX-1:0] shamt
);
    localparam NORM_TOP_INT = WMAN + 2;
    localparam NINPUT       = NORM_TOP_INT + 1;

    wire [((WINDEX + 1) * NINPUT)-1:0]          valid_stage;
    wire [((WINDEX + 1) * NINPUT * WINDEX)-1:0] shamt_stage;

    genvar i_leaf;
    genvar i_level;
    genvar i_node;
    generate
        for (i_leaf = 0; i_leaf < NINPUT; i_leaf = i_leaf + 1) begin : g_leaf
            localparam integer SHIFT = NORM_TOP_INT - i_leaf;
            assign valid_stage[i_leaf] = x[i_leaf];
            assign shamt_stage[i_leaf * WINDEX +: WINDEX] = SHIFT[WINDEX-1:0];
        end

        for (i_level = 0; i_level < WINDEX; i_level = i_level + 1) begin : g_level
            localparam integer IN_COUNT  = (NINPUT + (1 << i_level) - 1) >> i_level;
            localparam integer OUT_COUNT = (IN_COUNT + 1) >> 1;
            for (i_node = 0; i_node < OUT_COUNT; i_node = i_node + 1) begin : g_node
                localparam integer OUT       = (i_level + 1) * NINPUT + i_node;
                localparam integer LO        = i_level * NINPUT + (2 * i_node);
                localparam integer HI        = LO + 1;
                localparam integer OUT_INDEX = OUT * WINDEX;
                localparam integer LO_INDEX  = LO * WINDEX;
                localparam integer HI_INDEX  = HI * WINDEX;

                wire [WINDEX-1:0] shamt_lo = shamt_stage[LO_INDEX +: WINDEX];

                if ((2 * i_node + 1) < IN_COUNT) begin : g_pair
                    wire [WINDEX-1:0] shamt_hi = shamt_stage[HI_INDEX +: WINDEX];

                    assign valid_stage[OUT] = valid_stage[LO] | valid_stage[HI];
                    assign shamt_stage[OUT_INDEX +: WINDEX] = valid_stage[HI] ? shamt_hi : shamt_lo;
                end else begin : g_odd
                    assign valid_stage[OUT] = valid_stage[LO];
                    assign shamt_stage[OUT_INDEX +: WINDEX] = shamt_lo;
                end
            end
        end
    endgenerate

    assign zero  = ~valid_stage[WINDEX * NINPUT];
    assign shamt = shamt_stage[(WINDEX * NINPUT * WINDEX) +: WINDEX];
endmodule


// Apply the registered subtraction-normalization shift and exponent correction.
module _zkf_add_sub_shift_apply #(parameter WMAN = 18, parameter WINDEX = $clog2(WMAN + 4)) (
    input wire   [WMAN+2:0] x,
    input wire [WINDEX-1:0] shamt,

    output wire [WMAN-1:0] significand,
    output wire            guard,
    output wire            round,
    output wire            sticky
);
    localparam NORM_TOP_INT = WMAN + 2;
    wire [NORM_TOP_INT:0] shifted = x[NORM_TOP_INT:0] << shamt;
    assign significand = shifted[NORM_TOP_INT -: WMAN];
    assign guard       = shifted[2];
    assign round       = shifted[1];
    assign sticky      = shifted[0];
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
