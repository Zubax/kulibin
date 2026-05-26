/// Streamed Zubax Kulibin fused multiply-add: y = a*b + c, correctly rounded with a single final rounding.
/// Register stages: 5+STAGE_PRODUCT+STAGE_ALIGN+STAGE_OUTPUT end-to-end (default 5).
///
/// The exact 2*WMAN-bit product is carried through alignment, add, and normalize, so a*b+c is rounded once.
/// That single rounding is the reason a true FMA is fundamentally wider than a chained zkf_mul -> zkf_add
/// The structure mirrors zkf_add with operand A replaced by the multiplier's full product.
///
/// STAGE_PRODUCT=0: single-cycle multiplication (combinational a*b into the product register, default).
/// STAGE_PRODUCT>=1: split the product into a 2*2 grid of partial products registered one stage earlier and
///   summed in the next cycle, exactly as zkf_mul does, so the DSP cascade closes in two periods (+1 cycle).
///
/// STAGE_ALIGN=0: single-cycle alignment shifter (default).
/// STAGE_ALIGN=1: split the radix-4 cascade (+1 cycle).
///
/// STAGE_OUTPUT=0: combinational packed output (default).
/// STAGE_OUTPUT=1: registered output (+1 cycle).

`default_nettype none

module zkf_fma #(
    parameter WEXP          = 6,    // exponent field width
    parameter WMAN          = 18,   // significand precision including the hidden bit
    parameter STAGE_PRODUCT = 0,    // 0 = combinational multiply; >=1 = split 2*2 product grid (+1 cycle)
    parameter STAGE_ALIGN   = 0,    // 0 = single-cycle alignment; 1 = split alignment shifter (+1 cycle)
    parameter STAGE_OUTPUT  = 0     // 0 = combinational output; 1 = registered output (+1 cycle)
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,
    input wire [WEXP+WMAN-1:0] c,

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
    localparam WMAG  = 2 * WMAN;            // full product width
    localparam WGRS  = 3;                   // guard/round/sticky pad below the operand significands
    localparam WF    = WMAG + WGRS;         // unified accumulation/normalize width
    localparam WRAW  = WF + 1;              // carry-extended adder width
    localparam WINDEX = $clog2(WF);         // normalize-count / shift index width
    localparam WEU    = WEXP + 2;           // signed biased exponent field (holds the product exponent sum)
    localparam WDIFF  = WEU + 1;            // signed exponent-difference field (no overflow vs EXP_MIN)
    localparam WSHIFT = (WDIFF > (WINDEX + 1)) ? WDIFF : (WINDEX + 1);

    localparam [WEXP-1:0] EXP_BIAS = {1'b0, {WEXP-1{1'b1}}};
    localparam [WEXP-1:0] EXP_INF  = {WEXP{1'b1}};
    // Most-negative WEU value: any finite operand sorts above it, so a zero/non-finite operand (whose datapath
    // magnitude is forced to 0) is always selected as the "small" operand and contributes nothing.
    localparam signed [WEU-1:0] EXP_MIN = {1'b1, {(WEU-1){1'b0}}};

    // -- Operand decode/classification --------------------------------------------------------------------------
    wire             a_sign = a[WFULL-1];
    wire             b_sign = b[WFULL-1];
    wire             c_sign = c[WFULL-1];
    wire [WEXP-1:0]  a_exp  = a[WFULL-2:WFRAC];
    wire [WEXP-1:0]  b_exp  = b[WFULL-2:WFRAC];
    wire [WEXP-1:0]  c_exp  = c[WFULL-2:WFRAC];
    wire [WFRAC-1:0] a_frac = a[WFRAC-1:0];
    wire [WFRAC-1:0] b_frac = b[WFRAC-1:0];
    wire [WFRAC-1:0] c_frac = c[WFRAC-1:0];

    wire a_zero = ~|a_exp;
    wire b_zero = ~|b_exp;
    wire c_zero = ~|c_exp;
    wire a_inf  = &a_exp;
    wire b_inf  = &b_exp;
    wire c_inf  = &c_exp;
    // verilator coverage_off
    // The reconstructed significands' MSB is the always-1 hidden bit (fractions exercised via the ports).
    wire [WMAN-1:0] a_sig = {1'b1, a_frac};
    wire [WMAN-1:0] b_sig = {1'b1, b_frac};
    wire [WMAN-1:0] c_sig = {1'b1, c_frac};
    // verilator coverage_on

    // Product classification matches zkf_mul: a or b zero gives a zero product (so 0*inf collapses to zero and is
    // overridden only by c's infinity below); otherwise an infinite operand gives an infinite product.
    wire p_zero = a_zero | b_zero;
    wire p_inf  = ~p_zero & (a_inf | b_inf);
    wire p_sign = a_sign ^ b_sign;

    // Biased product exponent base, a_exp + b_exp - BIAS. The +product_high adjust is added at stage 0 once the
    // product's leading bit is known. Carrying the BIASED exponent (rather than unbiased) lets the packer skip its
    // bias add (EXP_IS_BIASED=1), keeping that adder off the result-exponent critical path, exactly as zkf_add does.
    // verilator coverage_off
    // Zero-extension padding of non-negative exponent fields plus the compile-time-constant bias.
    wire signed [WEU-1:0] a_exp_ext = {{(WEU-WEXP){1'b0}}, a_exp};
    wire signed [WEU-1:0] b_exp_ext = {{(WEU-WEXP){1'b0}}, b_exp};
    wire signed [WEU-1:0] bias_ext  = {{(WEU-WEXP){1'b0}}, EXP_BIAS};
    // verilator coverage_on
    wire signed [WEU-1:0] p_exp_base = a_exp_ext + b_exp_ext - bias_ext;

    // -- Multiply (optionally split) + payload carried to the product register ----------------------------------
    wire                  mag_valid;
    wire       [WMAG-1:0] mag;
    wire                  m_p_sign;
    wire                  m_p_zero;
    wire                  m_p_inf;
    wire signed [WEU-1:0] m_p_exp_base;
    wire       [WMAN-1:0] m_c_sig;
    wire       [WEXP-1:0] m_c_exp;
    wire                  m_c_sign;
    wire                  m_c_zero;
    wire                  m_c_inf;

    generate
        if (STAGE_PRODUCT == 0) begin : g_mul_unsplit
            assign mag          = a_sig * b_sig;
            assign mag_valid    = in_valid;
            assign m_p_sign     = p_sign;
            assign m_p_zero     = p_zero;
            assign m_p_inf      = p_inf;
            assign m_p_exp_base = p_exp_base;
            assign m_c_sig      = c_sig;
            assign m_c_exp      = c_exp;
            assign m_c_sign     = c_sign;
            assign m_c_zero     = c_zero;
            assign m_c_inf      = c_inf;
        end else begin : g_mul_split
            // a_sig*b_sig via a 2*2 grid of half-width partial products registered one cycle earlier, summed here
            // (cf. zkf_mul); the c bundle and product control ride the same register so they stay aligned.
            localparam WLO = (WMAN + 1) / 2;
            localparam WHI = WMAN - WLO;
            // verilator coverage_off
            wire [WLO-1:0] a_lo = a_sig[WLO-1:0];
            wire [WHI-1:0] a_hi = a_sig[WMAN-1:WLO];
            wire [WLO-1:0] b_lo = b_sig[WLO-1:0];
            wire [WHI-1:0] b_hi = b_sig[WMAN-1:WLO];
            // verilator coverage_on

            reg                  g_valid;
            reg                  g_p_sign;
            reg                  g_p_zero;
            reg                  g_p_inf;
            reg signed [WEU-1:0] g_p_exp_base;
            reg       [WMAN-1:0] g_c_sig;
            reg       [WEXP-1:0] g_c_exp;
            reg                  g_c_sign;
            reg                  g_c_zero;
            reg                  g_c_inf;
            reg [(WLO+WLO)-1:0]  g_p_ll;
            reg [(WLO+WHI)-1:0]  g_p_lh;
            reg [(WHI+WLO)-1:0]  g_p_hl;
            reg [(WHI+WHI)-1:0]  g_p_hh;

            always @(posedge clk) begin
                if (rst) g_valid <= 1'b0;
                else     g_valid <= in_valid;
                g_p_sign     <= p_sign;
                g_p_zero     <= p_zero;
                g_p_inf      <= p_inf;
                g_p_exp_base <= p_exp_base;
                g_c_sig      <= c_sig;
                g_c_exp      <= c_exp;
                g_c_sign     <= c_sign;
                g_c_zero     <= c_zero;
                g_c_inf      <= c_inf;
                g_p_ll       <= a_lo * b_lo;
                g_p_lh       <= a_lo * b_hi;
                g_p_hl       <= a_hi * b_lo;
                g_p_hh       <= a_hi * b_hi;
            end

            // verilator coverage_off
            wire [WMAG-1:0] hh_ext = {{(WMAG - 2*WHI - 2*WLO){1'b0}}, g_p_hh, {(2*WLO){1'b0}}};
            wire [WMAG-1:0] lh_ext = {{(WMAG - WLO - WHI - WLO){1'b0}}, g_p_lh, {WLO{1'b0}}};
            wire [WMAG-1:0] hl_ext = {{(WMAG - WHI - WLO - WLO){1'b0}}, g_p_hl, {WLO{1'b0}}};
            wire [WMAG-1:0] ll_ext = {{(WMAG - 2*WLO){1'b0}}, g_p_ll};
            // verilator coverage_on
            assign mag          = hh_ext + lh_ext + hl_ext + ll_ext;
            assign mag_valid    = g_valid;
            assign m_p_sign     = g_p_sign;
            assign m_p_zero     = g_p_zero;
            assign m_p_inf      = g_p_inf;
            assign m_p_exp_base = g_p_exp_base;
            assign m_c_sig      = g_c_sig;
            assign m_c_exp      = g_c_exp;
            assign m_c_sign     = g_c_sign;
            assign m_c_zero     = g_c_zero;
            assign m_c_inf      = g_c_inf;
        end
    endgenerate

    // -- Product stage register: full product magnitude + product control + decoded c bundle --------------------
    reg                  pr_valid;
    reg       [WMAG-1:0] pr_mag;
    reg                  pr_p_sign;
    reg                  pr_p_zero;
    reg                  pr_p_inf;
    reg signed [WEU-1:0] pr_p_exp_base;
    reg       [WMAN-1:0] pr_c_sig;
    reg       [WEXP-1:0] pr_c_exp;
    reg                  pr_c_sign;
    reg                  pr_c_zero;
    reg                  pr_c_inf;

    // -- Stage 0 combinational: normalize product, classify, magnitude-order against c -------------------------
    wire             pr_p_finite = ~pr_p_zero & ~pr_p_inf;
    wire             pr_c_finite = ~pr_c_zero & ~pr_c_inf;
    // A nonzero hidden-bit product has its leading one in bit WMAG-1 (value in [2,4)) or WMAG-2 (value in [1,2)).
    // Normalize to leading one at WMAG-1 so the product is, in form, a 2*WMAN-bit significand in [1,2).
    wire             product_high = pr_mag[WMAG-1];
    // verilator coverage_off
    wire  [WMAG-1:0] product_norm = product_high ? pr_mag : (pr_mag << 1);
    // product_high contributes the +1 normalize adjust in a WEU-wide field; only its low bit toggles.
    wire signed [WEU-1:0] product_high_ext = {{(WEU-1){1'b0}}, product_high};
    // verilator coverage_on

    // Effective biased MSB exponents (c's biased exponent is exactly its stored field). A non-finite/zero operand
    // contributes magnitude 0 (key masked to 0) and is pinned to EXP_MIN so it always sorts as the smaller operand.
    // Ordering is bias-invariant, so the magnitude compare below is unaffected by working in the biased domain.
    wire signed [WEU-1:0] ep_finite = pr_p_exp_base + product_high_ext;
    wire signed [WEU-1:0] ec_finite = {{(WEU-WEXP){1'b0}}, pr_c_exp};
    wire signed [WEU-1:0] ep_eff    = pr_p_finite ? ep_finite : EXP_MIN;
    wire signed [WEU-1:0] ec_eff    = pr_c_finite ? ec_finite : EXP_MIN;

    wire [WMAG-1:0] p_key = pr_p_finite ? product_norm : {WMAG{1'b0}};
    wire [WMAN-1:0] c_key = pr_c_finite ? pr_c_sig     : {WMAN{1'b0}};
    // c left-aligned into the product's width for the equal-exponent magnitude tie-break.
    wire [WMAG-1:0] c_key_wide = {c_key, {WMAN{1'b0}}};

    // Signed exponent difference (sign-extended to WDIFF so EXP_MIN cannot overflow).
    wire signed [WDIFF-1:0] ediff = {ep_eff[WEU-1], ep_eff} - {ec_eff[WEU-1], ec_eff};
    wire ediff_zero = ~|ediff;
    wire ediff_pos  = ~ediff[WDIFF-1] & ~ediff_zero;
    // Equal-exponent tie-break by significand: product wins ties so large >= small always holds.
    // verilator coverage_off
    wire [WMAG:0] tie_diff = {1'b0, p_key} - {1'b0, c_key_wide};
    // verilator coverage_on
    wire p_ge_c_tie  = ~tie_diff[WMAG];
    wire product_ge_c = ediff_pos | (ediff_zero & p_ge_c_tie);

    // Absolute exponent difference = alignment right-shift for the smaller operand.
    // verilator coverage_off
    wire [WDIFF-1:0] exp_diff_abs = ediff[WDIFF-1] ? (~ediff + 1'b1) : ediff;
    // verilator coverage_on

    // Anchor exponent and the two operands extended (MSB-aligned) into the WF field.
    wire signed [WEU-1:0] anchor_exp = product_ge_c ? ep_eff : ec_eff;
    wire         [WF-1:0] large_ext  = product_ge_c ? {p_key, {WGRS{1'b0}}} : {c_key, {(WF-WMAN){1'b0}}};
    wire         [WF-1:0] small_ext  = product_ge_c ? {c_key, {(WF-WMAN){1'b0}}} : {p_key, {WGRS{1'b0}}};

    wire same_sign   = ~(pr_p_sign ^ pr_c_sign);
    wire finite_sign = product_ge_c ? pr_p_sign : pr_c_sign;
    wire inf_sign    = (pr_p_inf & pr_p_sign) | (pr_c_inf & pr_c_sign);
    wire force_inf   = pr_p_inf | pr_c_inf;
    wire force_zero  = pr_p_inf & pr_c_inf & (pr_p_sign != pr_c_sign);

    // -- Stage 0 register: magnitude-ordered operands, shift amount, special-case controls ----------------------
    reg                  s0_valid;
    reg                  s0_finite_sign;
    reg                  s0_inf_sign;
    reg                  s0_same_sign;
    reg                  s0_force_zero;
    reg                  s0_force_inf;
    reg signed [WEU-1:0] s0_anchor_exp;
    reg     [WSHIFT-1:0] s0_exp_diff;
    reg        [WF-1:0]  s0_large_ext;
    reg        [WF-1:0]  s0_small_ext;

    // Alignment shifter on the smaller operand; STAGE_ALIGN splits the radix-4 cascade across two cycles.
    wire [WF-1:0] s0_small_aligned;
    _zkf_rshift_sticky #(.W(WF), .WSHIFT(WSHIFT), .STAGE_SPLIT(STAGE_ALIGN)) u_align_small (
        .clk(clk),
        .x(s0_small_ext),
        .shamt(s0_exp_diff),
        .y(s0_small_aligned)
    );

    // Intermediate s0b: combinational alias of s0_* when STAGE_ALIGN=0; a delay register matching the shifter's
    // extra cycle when STAGE_ALIGN!=0 (mirrors zkf_add's s0b).
    wire                  s0b_valid;
    wire                  s0b_finite_sign;
    wire                  s0b_inf_sign;
    wire                  s0b_same_sign;
    wire                  s0b_force_zero;
    wire                  s0b_force_inf;
    wire signed [WEU-1:0] s0b_anchor_exp;
    wire        [WF-1:0]  s0b_large_ext;

    generate
        if (STAGE_ALIGN == 0) begin : g_no_align_register
            assign s0b_valid       = s0_valid;
            assign s0b_finite_sign = s0_finite_sign;
            assign s0b_inf_sign    = s0_inf_sign;
            assign s0b_same_sign   = s0_same_sign;
            assign s0b_force_zero  = s0_force_zero;
            assign s0b_force_inf   = s0_force_inf;
            assign s0b_anchor_exp  = s0_anchor_exp;
            assign s0b_large_ext   = s0_large_ext;
        end else begin : g_align_register
            reg                  r_valid;
            reg                  r_finite_sign;
            reg                  r_inf_sign;
            reg                  r_same_sign;
            reg                  r_force_zero;
            reg                  r_force_inf;
            reg signed [WEU-1:0] r_anchor_exp;
            reg        [WF-1:0]  r_large_ext;
            always @(posedge clk) begin
                if (rst) r_valid <= 1'b0;
                else     r_valid <= s0_valid;
                r_finite_sign <= s0_finite_sign;
                r_inf_sign    <= s0_inf_sign;
                r_same_sign   <= s0_same_sign;
                r_force_zero  <= s0_force_zero;
                r_force_inf   <= s0_force_inf;
                r_anchor_exp  <= s0_anchor_exp;
                r_large_ext   <= s0_large_ext;
            end
            assign s0b_valid       = r_valid;
            assign s0b_finite_sign = r_finite_sign;
            assign s0b_inf_sign    = r_inf_sign;
            assign s0b_same_sign   = r_same_sign;
            assign s0b_force_zero  = r_force_zero;
            assign s0b_force_inf   = r_force_inf;
            assign s0b_anchor_exp  = r_anchor_exp;
            assign s0b_large_ext   = r_large_ext;
        end
    endgenerate

    // -- Stage 1 register: aligned operands ---------------------------------------------------------------------
    reg                  s1_valid;
    reg                  s1_finite_sign;
    reg                  s1_inf_sign;
    reg                  s1_same_sign;
    reg                  s1_force_zero;
    reg                  s1_force_inf;
    reg signed [WEU-1:0] s1_anchor_exp;
    reg        [WF-1:0]  s1_large_ext;
    reg        [WF-1:0]  s1_small_aligned;

    // Single carry chain: the larger operand is the minuend, the aligned smaller one is added (same sign) or
    // two's-complemented and added with carry-in (opposite sign). large >= small guarantees a non-negative result.
    // verilator coverage_off
    wire [WRAW-1:0] s1_adder_a     = {1'b0, s1_large_ext};
    wire [WRAW-1:0] s1_adder_b_abs = {1'b0, s1_small_aligned};
    // verilator coverage_on
    wire [WRAW-1:0] s1_adder_b     = s1_same_sign ? s1_adder_b_abs : ~s1_adder_b_abs;
    wire [WRAW-1:0] s1_raw_result  = s1_adder_a + s1_adder_b + {{(WRAW-1){1'b0}}, !s1_same_sign};
    wire            s1_result_sign = s1_force_inf ? s1_inf_sign : s1_finite_sign;

    // -- Stage 2 register: raw add/subtract result --------------------------------------------------------------
    reg                  s2_valid;
    reg                  s2_sign;
    reg                  s2_same_sign;
    reg                  s2_force_zero;
    reg                  s2_force_inf;
    reg signed [WEU-1:0] s2_anchor_exp;
    reg       [WRAW-1:0] s2_raw_result;

    // Same-sign addition: leading one stays at bit WF-1, or carries to bit WF; a 1-bit normalize, no left shift.
    wire                  s2_add_carry  = s2_raw_result[WF];
    wire signed [WEU-1:0] s2_add_exp    = s2_anchor_exp + {{(WEU-1){1'b0}}, s2_add_carry};
    wire       [WMAN-1:0] s2_add_sig    = s2_add_carry ? s2_raw_result[WF -: WMAN]     : s2_raw_result[WF-1 -: WMAN];
    wire                  s2_add_guard  = s2_add_carry ? s2_raw_result[WF-WMAN]        : s2_raw_result[WF-WMAN-1];
    wire                  s2_add_round  = s2_add_carry ? s2_raw_result[WF-WMAN-1]      : s2_raw_result[WF-WMAN-2];
    wire                  s2_add_sticky = s2_add_carry ? (|s2_raw_result[WF-WMAN-2:0]) : (|s2_raw_result[WF-WMAN-3:0]);

    // Opposite-sign subtraction can cancel down into the product's low half, so the close-cancellation normalize
    // scans the FULL WF-bit magnitude (this full width is the irreducible cost of correct FMA rounding). The
    // normshift's STAGE_SPLIT=1 register sits on the s2->s3 boundary, so its outputs are valid in the s3 cone.
    wire              s3_sub_zero;
    wire [WINDEX-1:0] s3_sub_shift;
    // verilator coverage_off
    wire     [WF-1:0] s3_sub_aligned;
    // verilator coverage_on
    _zkf_normshift #(.W(WF), .WSHAMT(WINDEX), .STAGE_SPLIT(1)) u_sub_norm (
        .clk(clk),
        .x(s2_raw_result[WF-1:0]),
        .zero(s3_sub_zero),
        .count(s3_sub_shift),
        .y(s3_sub_aligned)
    );
    wire [WMAN-1:0] s3_sub_sig    = s3_sub_aligned[WF-1 -: WMAN];
    wire            s3_sub_guard  = s3_sub_aligned[WF-WMAN-1];
    wire            s3_sub_round  = s3_sub_aligned[WF-WMAN-2];
    wire            s3_sub_sticky = |s3_sub_aligned[WF-WMAN-3:0];

    // -- Stage 3 register: add-path results; sub-path comes from the normshift's post-split outputs -------------
    reg                  s3_valid;
    reg                  s3_sign;
    reg                  s3_same_sign;
    reg                  s3_force_zero;
    reg                  s3_force_inf;
    reg signed [WEU-1:0] s3_anchor_exp;     // base anchor biased exponent, for the sub-path correction
    reg signed [WEU-1:0] s3_add_exp;        // add-path exponent, resolved in the s2 cone
    reg       [WMAN-1:0] s3_add_sig;
    reg                  s3_add_guard;
    reg                  s3_add_round;
    reg                  s3_add_sticky;

    // Sub-path exponent correction: anchor minus the normalize left-shift (can go negative on underflow).
    // verilator coverage_off
    wire signed [WEU-1:0] s3_sub_shift_ext = {{(WEU-WINDEX){1'b0}}, s3_sub_shift};
    // verilator coverage_on
    wire signed [WEU-1:0] s3_sub_exp = s3_anchor_exp - s3_sub_shift_ext;

    wire signed [WEU-1:0] s3_pack_exp = s3_same_sign ? s3_add_exp : s3_sub_exp;
    wire s3_finite_zero = s3_same_sign ? (~|{s3_add_sig, s3_add_guard, s3_add_round, s3_add_sticky}) : s3_sub_zero;
    wire            s3_pack_force_zero = s3_force_zero || (!s3_force_inf && s3_finite_zero);
    wire [WMAN-1:0] s3_pack_sig        = s3_same_sign ? s3_add_sig    : s3_sub_sig;
    wire            s3_pack_guard      = s3_same_sign ? s3_add_guard  : s3_sub_guard;
    wire            s3_pack_round      = s3_same_sign ? s3_add_round  : s3_sub_round;
    wire            s3_pack_sticky     = s3_same_sign ? s3_add_sticky : s3_sub_sticky;

    _zkf_pack #(
        .WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEU), .EXP_IS_BIASED(1), .STAGE_OUTPUT(STAGE_OUTPUT)
    ) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s3_valid),
        .sign(s3_sign),
        .force_zero(s3_pack_force_zero),
        .force_inf(s3_force_inf),
        .exp_unbiased(s3_pack_exp),
        .significand(s3_pack_sig),
        .guard(s3_pack_guard),
        .round(s3_pack_round),
        .sticky(s3_pack_sticky),
        .out_valid(out_valid),
        .y(y)
    );

    // Reset only stream validity; payload registers free-run. s0b_valid is reset inside its generate block when
    // STAGE_ALIGN!=0, so this always block manages pr/s0/s1/s2/s3 validity only.
    always @(posedge clk) begin
        if (rst) begin
            pr_valid <= 1'b0;
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
        end else begin
            pr_valid <= mag_valid;
            s0_valid <= pr_valid;
            s1_valid <= s0b_valid;
            s2_valid <= s1_valid;
            s3_valid <= s2_valid;
        end

        // Product stage capture.
        pr_mag        <= mag;
        pr_p_sign     <= m_p_sign;
        pr_p_zero     <= m_p_zero;
        pr_p_inf      <= m_p_inf;
        pr_p_exp_base <= m_p_exp_base;
        pr_c_sig      <= m_c_sig;
        pr_c_exp      <= m_c_exp;
        pr_c_sign     <= m_c_sign;
        pr_c_zero     <= m_c_zero;
        pr_c_inf      <= m_c_inf;

        // Stage 0 capture: magnitude-ordered operands, alignment shift, special controls.
        s0_finite_sign <= finite_sign;
        s0_inf_sign    <= inf_sign;
        s0_same_sign   <= same_sign;
        s0_force_zero  <= force_zero;
        s0_force_inf   <= force_inf;
        s0_anchor_exp  <= anchor_exp;
        s0_exp_diff    <= {{(WSHIFT-WDIFF){1'b0}}, exp_diff_abs};
        s0_large_ext   <= large_ext;
        s0_small_ext   <= small_ext;

        // Stage 1 capture: aligned operands from s0b (s0_* directly or one-cycle-delayed when STAGE_ALIGN).
        s1_finite_sign   <= s0b_finite_sign;
        s1_inf_sign      <= s0b_inf_sign;
        s1_same_sign     <= s0b_same_sign;
        s1_force_zero    <= s0b_force_zero;
        s1_force_inf     <= s0b_force_inf;
        s1_anchor_exp    <= s0b_anchor_exp;
        s1_large_ext     <= s0b_large_ext;
        s1_small_aligned <= s0_small_aligned;

        // Stage 2 capture: the raw add/subtract result.
        s2_sign       <= s1_result_sign;
        s2_same_sign  <= s1_same_sign;
        s2_force_zero <= s1_force_zero;
        s2_force_inf  <= s1_force_inf;
        s2_anchor_exp <= s1_anchor_exp;
        s2_raw_result <= s1_raw_result;

        // Stage 3 capture: add-path normalization (sub-path lives in the normshift's internal register).
        s3_sign       <= s2_sign;
        s3_same_sign  <= s2_same_sign;
        s3_force_zero <= s2_force_zero;
        s3_force_inf  <= s2_force_inf;
        s3_anchor_exp <= s2_anchor_exp;
        s3_add_exp    <= s2_add_exp;
        s3_add_sig    <= s2_add_sig;
        s3_add_guard  <= s2_add_guard;
        s3_add_round  <= s2_add_round;
        s3_add_sticky <= s2_add_sticky;
    end
endmodule

`default_nettype wire
