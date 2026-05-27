/// Streamed Zubax Kulibin fused multiply-add: y = a*b + c, correctly rounded with a single final rounding.
/// Register stages: 5+STAGE_INPUT+STAGE_PRODUCT+STAGE_DECODE+STAGE_ALIGN+STAGE_NORMALIZE+STAGE_OUTPUT end-to-end.
///
/// The exact 2*WMAN-bit product is carried through alignment, add, and normalize, so a*b+c is rounded once.
/// That single rounding is the reason a true FMA is fundamentally wider than a chained zkf_mul -> zkf_add
/// The structure mirrors zkf_add with operand A replaced by the multiplier's full product.
///
/// STAGE_INPUT=0: operands feed the datapath combinationally (default).
/// STAGE_INPUT=1: latch the inputs before any combinational logic, isolating them from upstream paths (+1 cycle).
///
/// STAGE_PRODUCT=0: single-cycle multiplication (combinational a*b into the product register, default).
/// STAGE_PRODUCT=1: split the product into a 2*2 grid of partial products registered one stage earlier and
///   summed in the next cycle, exactly as zkf_mul does, so the DSP cascade closes in two periods (+1 cycle).
///
/// STAGE_DECODE=0: the decoded/normalized operands feed the magnitude-compare and operand-select combinationally.
/// STAGE_DECODE=1: register them first, splitting the wide compare+select cone (+1 cycle).
///
/// STAGE_ALIGN=0: single-cycle alignment shifter (default).
/// STAGE_ALIGN=1: split the radix-4 cascade (+1 cycle).
///
/// STAGE_NORMALIZE selects how deeply the close-cancellation normalize/round path is pipelined (0, 1 or 2):
///   0: the normalize + exponent correction feed the packer combinationally (default).
///   1: register the packer inputs, splitting that cone from the rounding adder (+1 cycle).
///   2: swap 1-split normalizer for a 3-segment one, realign the carried payload (+2 cycles).
///
/// STAGE_OUTPUT=0: combinational packed output (default).
/// STAGE_OUTPUT=1: registered output (+1 cycle).

`default_nettype none

module zkf_fma #(
    parameter WEXP            = 6,  // exponent field width
    parameter WMAN            = 18, // significand precision including the hidden bit
    parameter STAGE_INPUT     = 0,  // 0 = combinational inputs; 1 = latch inputs before any logic (+1 cycle)
    parameter STAGE_PRODUCT   = 0,  // 0 = combinational multiply; >=1 = split 2*2 product grid (+1 cycle)
    parameter STAGE_DECODE    = 0,  // 0 = decode feeds compare/select combinationally; 1 = register it (+1 cycle)
    parameter STAGE_ALIGN     = 0,  // 0 = single-cycle alignment; 1 = split alignment shifter (+1 cycle)
    parameter STAGE_NORMALIZE = 0,  // 0 = comb; 1 = register pack inputs; 2 = 3-segment normalizer
    parameter STAGE_OUTPUT    = 0   // 0 = combinational output; 1 = registered output (+1 cycle)
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
        // STAGE_NORMALIZE=2 selects the FMA-local 3-segment normalizer (_zkf_fma_norm3), which needs at least three
        // radix-4 levels - NL4 = ($clog2(2*WMAN+3)+1)/2 >= 3 - so its two register barriers land at distinct positions
        // and its latency is exactly 2, the +1 cycle the s2x payload realignment below assumes. NL4 >= 3 holds iff
        // 2*WMAN+3 >= 17, i.e. WMAN >= 7; below that the barriers collapse to one, the normalizer becomes 1-cycle, and
        // the sub path races ahead of the add path. STAGE_NORMALIZE=2 is a wide-format timing knob (the close-
        // cancellation normalize is only slow at large WMAN), so narrow formats never need it: reject at elaboration.
        if ((STAGE_NORMALIZE == 2) && (WMAN < 7)) begin : g_invalid_norm2_wman
            _zkf_invalid_fma_stage_normalize2_requires_wman_ge_7 u_invalid();
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
    // Signed biased exponent field. WEXP+2 holds the product exponent sum (a_exp+b_exp-BIAS, +1 normalize), but the
    // close-cancellation sub path computes anchor - normalize_shift, which reaches down to ~-(2*WMAN+1) (shift up to
    // WF-1). For small WEXP with large WMAN that underflows WEXP+2 and wraps to a spurious positive exponent (and the
    // s3_sub_shift zero-extension would even take a negative replication count), so the field must also cover the
    // shift range: WINDEX+2. WINDEX <= WEXP for the common formats, so this is a no-op there (6/18->8, 8/36->10).
    localparam WEU    = ((WEXP > WINDEX) ? WEXP : WINDEX) + 2;
    localparam WDIFF  = WEU + 1;            // signed exponent-difference field (no overflow vs EXP_MIN)
    localparam WSHIFT = (WDIFF > (WINDEX + 1)) ? WDIFF : (WINDEX + 1);

    localparam [WEXP-1:0] EXP_BIAS = {1'b0, {WEXP-1{1'b1}}};
    localparam [WEXP-1:0] EXP_INF  = {WEXP{1'b1}};
    // Most-negative WEU value: any finite operand sorts above it, so a zero/non-finite operand (whose datapath
    // magnitude is forced to 0) is always selected as the "small" operand and contributes nothing.
    localparam signed [WEU-1:0] EXP_MIN = {1'b1, {(WEU-1){1'b0}}};

    // Optional input register stage: latch the operands before any combinational logic (+1 cycle when STAGE_INPUT=1).
    wire             in_valid_q;
    wire [WFULL-1:0] a_q;
    wire [WFULL-1:0] b_q;
    wire [WFULL-1:0] c_q;
    _zkf_pipe #(.W(3*WFULL), .N(STAGE_INPUT ? 1 : 0)) u_input_pipe (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in({c, b, a}),
        .out_valid(in_valid_q), .out({c_q, b_q, a_q})
    );

    // -- Operand decode/classification --------------------------------------------------------------------------
    wire             a_sign = a_q[WFULL-1];
    wire             b_sign = b_q[WFULL-1];
    wire             c_sign = c_q[WFULL-1];
    wire [WEXP-1:0]  a_exp  = a_q[WFULL-2:WFRAC];
    wire [WEXP-1:0]  b_exp  = b_q[WFULL-2:WFRAC];
    wire [WEXP-1:0]  c_exp  = c_q[WFULL-2:WFRAC];
    wire [WFRAC-1:0] a_frac = a_q[WFRAC-1:0];
    wire [WFRAC-1:0] b_frac = b_q[WFRAC-1:0];
    wire [WFRAC-1:0] c_frac = c_q[WFRAC-1:0];

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

    // Biased product exponent base, a_exp + b_exp - BIAS. The +product_high normalize adjust is folded in just
    // before the product register (mag_ep_finite, see the retiming note there), once the product's leading bit is
    // known. Carrying the BIASED exponent (rather than unbiased) lets the packer skip its bias add (EXP_IS_BIASED=1),
    // keeping that adder off the result-exponent critical path, exactly as zkf_add does.
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
            assign mag_valid    = in_valid_q;
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
                else     g_valid <= in_valid_q;
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

    // -- Product normalization, retimed to the producing side of the product register ---------------------------
    // A nonzero hidden-bit product has its leading one at bit WMAG-1 (value in [2,4)) or WMAG-2 (value in [1,2)).
    // Doing the normalize HERE - before the product register, in the slack of the multiply stage - instead of after
    // it keeps the +1 exponent adjust and the normalize shift off the HEAD of the magnitude-compare cone (the
    // critical path), so that cone now begins at the exponent subtract rather than clk->q -> adder. mag and
    // m_p_exp_base are the common interface of both STAGE_PRODUCT branches, so this retiming is identical for the
    // split and unsplit multiply.
    wire                  mag_high      = mag[WMAG-1];
    // verilator coverage_off
    wire        [WMAG-1:0] mag_norm      = mag_high ? mag : (mag << 1);
    wire signed [WEU-1:0]  mag_high_ext  = {{(WEU-1){1'b0}}, mag_high};
    // verilator coverage_on
    wire signed [WEU-1:0]  mag_ep_finite = m_p_exp_base + mag_high_ext;

    // -- Product stage register: normalized product magnitude + adjusted exponent + product control + c bundle ---
    reg                  pr_valid;
    reg       [WMAG-1:0] pr_product_norm;
    reg                  pr_p_sign;
    reg                  pr_p_zero;
    reg                  pr_p_inf;
    reg signed [WEU-1:0] pr_ep_finite;
    reg       [WMAN-1:0] pr_c_sig;
    reg       [WEXP-1:0] pr_c_exp;
    reg                  pr_c_sign;
    reg                  pr_c_zero;
    reg                  pr_c_inf;

    // -- Decode / normalize (combinational from the product stage) ----------------------------------------------
    wire             pr_p_finite = ~pr_p_zero & ~pr_p_inf;
    wire             pr_c_finite = ~pr_c_zero & ~pr_c_inf;
    // pr_product_norm and pr_ep_finite arrive already normalized from the product register (see the retiming note
    // above the register): pr_product_norm is the product significand with its leading one at bit WMAG-1, and
    // pr_ep_finite is its biased exponent with the +1 normalize adjust already folded in.
    //
    // Effective biased MSB exponents (c's biased exponent is exactly its stored field). A non-finite/zero operand
    // contributes magnitude 0 (key masked to 0) and is pinned to EXP_MIN so it always sorts as the smaller operand.
    // Ordering is bias-invariant, so the magnitude compare below is unaffected by working in the biased domain.
    // verilator coverage_off
    // High (WEU-WEXP) bits are constant zero-extension; the value bits mirror pr_c_exp (covered there).
    wire signed [WEU-1:0] ec_finite = {{(WEU-WEXP){1'b0}}, pr_c_exp};
    // verilator coverage_on

    // Optional decode register (STAGE_DECODE): splits the decode/normalize cone above from the magnitude-compare and
    // operand-select cone below. That compare+select cone (a 2*WMAN-bit subtract feeding the WF-wide large/small
    // operand mux) is the critical path at large WMAN, so registering the decoded bundle here closes timing there.
    // The decoded keys are formed directly into d_* in each branch (no intermediate alias net), so STAGE_DECODE=0 is
    // structurally identical to feeding the magnitude compare straight from the product stage.
    wire                  d_valid;
    wire       [WMAG-1:0] d_p_key;
    wire       [WMAN-1:0] d_c_key;
    wire signed [WEU-1:0] d_ep_eff;
    // verilator coverage_off
    wire signed [WEU-1:0] d_ec_eff;  // c effective exponent: high zero-extension bits never toggle (value via pr_c_exp)
    // verilator coverage_on
    wire                  d_p_sign;
    wire                  d_c_sign;
    wire                  d_p_inf;
    wire                  d_c_inf;

    generate
        if (STAGE_DECODE == 0) begin : g_no_decode_register
            assign d_valid  = pr_valid;
            assign d_p_key  = pr_p_finite ? pr_product_norm : {WMAG{1'b0}};
            assign d_c_key  = pr_c_finite ? pr_c_sig        : {WMAN{1'b0}};
            assign d_ep_eff = pr_p_finite ? pr_ep_finite : EXP_MIN;
            assign d_ec_eff = pr_c_finite ? ec_finite : EXP_MIN;
            assign d_p_sign = pr_p_sign;
            assign d_c_sign = pr_c_sign;
            assign d_p_inf  = pr_p_inf;
            assign d_c_inf  = pr_c_inf;
        end else begin : g_decode_register
            reg                  r_valid;
            reg       [WMAG-1:0] r_p_key;
            reg       [WMAN-1:0] r_c_key;
            reg signed [WEU-1:0] r_ep_eff;
            // verilator coverage_off
            reg signed [WEU-1:0] r_ec_eff;  // c effective exponent: high zero-extension bits never toggle
            // verilator coverage_on
            reg                  r_p_sign;
            reg                  r_c_sign;
            reg                  r_p_inf;
            reg                  r_c_inf;
            always @(posedge clk) begin
                if (rst) r_valid <= 1'b0;
                else     r_valid <= pr_valid;
                r_p_key  <= pr_p_finite ? pr_product_norm : {WMAG{1'b0}};
                r_c_key  <= pr_c_finite ? pr_c_sig        : {WMAN{1'b0}};
                r_ep_eff <= pr_p_finite ? pr_ep_finite : EXP_MIN;
                r_ec_eff <= pr_c_finite ? ec_finite : EXP_MIN;
                r_p_sign <= pr_p_sign;
                r_c_sign <= pr_c_sign;
                r_p_inf  <= pr_p_inf;
                r_c_inf  <= pr_c_inf;
            end
            assign d_valid  = r_valid;
            assign d_p_key  = r_p_key;
            assign d_c_key  = r_c_key;
            assign d_ep_eff = r_ep_eff;
            assign d_ec_eff = r_ec_eff;
            assign d_p_sign = r_p_sign;
            assign d_c_sign = r_c_sign;
            assign d_p_inf  = r_p_inf;
            assign d_c_inf  = r_c_inf;
        end
    endgenerate

    // -- Magnitude-order + operand select (combinational from the decoded bundle) -------------------------------
    // c left-aligned into the product's width for the equal-exponent magnitude tie-break. The low WMAN bits are
    // structural zero padding (never toggle); the data bits mirror d_c_key (covered there).
    // verilator coverage_off
    wire [WMAG-1:0] c_key_wide = {d_c_key, {WMAN{1'b0}}};
    // verilator coverage_on

    // Signed exponent difference (sign-extended to WDIFF so EXP_MIN cannot overflow).
    wire signed [WDIFF-1:0] ediff = {d_ep_eff[WEU-1], d_ep_eff} - {d_ec_eff[WEU-1], d_ec_eff};
    // Exponent equality from the operands, in parallel with the subtract (off its carry chain): both operands are
    // sign-extended from WEU to WDIFF identically, so the WEU fields being equal is exact and equals ~|ediff. This
    // keeps the wide zero-reduction out of the product_ge_c serial path, which now waits only on the subtract sign.
    wire ediff_zero = ~|(d_ep_eff ^ d_ec_eff);
    wire ediff_pos  = ~ediff[WDIFF-1] & ~ediff_zero;
    // Equal-exponent tie-break by significand: product wins ties so large >= small always holds.
    // verilator coverage_off
    wire [WMAG:0] tie_diff = {1'b0, d_p_key} - {1'b0, c_key_wide};
    // verilator coverage_on
    wire p_ge_c_tie  = ~tie_diff[WMAG];
    wire product_ge_c = ediff_pos | (ediff_zero & p_ge_c_tie);

    // Absolute exponent difference = alignment right-shift for the smaller operand.
    // verilator coverage_off
    wire [WDIFF-1:0] exp_diff_abs = ediff[WDIFF-1] ? (~ediff + 1'b1) : ediff;
    // verilator coverage_on

    // Anchor exponent and the two operands extended (MSB-aligned) into the WF field.
    wire signed [WEU-1:0] anchor_exp = product_ge_c ? d_ep_eff : d_ec_eff;
    // verilator coverage_off
    // Low padding bits (WGRS / WF-WMAN zeros) never toggle; the operand bits mirror d_p_key/d_c_key (covered there).
    wire         [WF-1:0] large_ext  = product_ge_c ? {d_p_key, {WGRS{1'b0}}} : {d_c_key, {(WF-WMAN){1'b0}}};
    wire         [WF-1:0] small_ext  = product_ge_c ? {d_c_key, {(WF-WMAN){1'b0}}} : {d_p_key, {WGRS{1'b0}}};
    // verilator coverage_on

    wire same_sign   = ~(d_p_sign ^ d_c_sign);
    wire finite_sign = product_ge_c ? d_p_sign : d_c_sign;
    wire inf_sign    = (d_p_inf & d_p_sign) | (d_c_inf & d_c_sign);
    wire force_inf   = d_p_inf | d_c_inf;
    wire force_zero  = d_p_inf & d_c_inf & (d_p_sign != d_c_sign);

    // -- Stage 0 register: magnitude-ordered operands, shift amount, special-case controls ----------------------
    reg                  s0_valid;
    reg                  s0_finite_sign;
    reg                  s0_inf_sign;
    reg                  s0_same_sign;
    reg                  s0_force_zero;
    reg                  s0_force_inf;
    reg signed [WEU-1:0] s0_anchor_exp;
    // verilator coverage_off
    // s0_exp_diff top bit is unreachable (|ediff| < 2^(WSHIFT-1)); s0_large/small_ext low bits are zero padding.
    reg     [WSHIFT-1:0] s0_exp_diff;
    reg        [WF-1:0]  s0_large_ext;
    reg        [WF-1:0]  s0_small_ext;
    // verilator coverage_on

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
    // verilator coverage_off
    wire        [WF-1:0]  s0b_large_ext;  // low padding bits never toggle (operand bits via d_p_key/d_c_key)
    // verilator coverage_on

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
            // verilator coverage_off
            reg        [WF-1:0]  r_large_ext;  // low padding bits never toggle (operand bits via d_p_key/d_c_key)
            // verilator coverage_on
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
    // verilator coverage_off
    reg        [WF-1:0]  s1_large_ext;  // low padding bits never toggle (operand bits via d_p_key/d_c_key)
    // verilator coverage_on
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
    generate
        if (STAGE_NORMALIZE < 2) begin : g_subnorm
            _zkf_normshift #(.W(WF), .WSHAMT(WINDEX), .STAGE_SPLIT(1)) u_sub_norm (
                .clk(clk),
                .x(s2_raw_result[WF-1:0]),
                .zero(s3_sub_zero),
                .count(s3_sub_shift),
                .y(s3_sub_aligned)
            );
        end else begin : g_subnorm_deep
            _zkf_fma_norm3 #(.W(WF), .WSHAMT(WINDEX)) u_sub_norm (
                .clk(clk),
                .x(s2_raw_result[WF-1:0]),
                .zero(s3_sub_zero),
                .count(s3_sub_shift),
                .y(s3_sub_aligned)
            );
        end
    endgenerate
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

    // Optional packer-input register (STAGE_NORMALIZE): splits the close-cancellation normalize + exponent
    // correction cone from the packer's rounding adder (the s3 critical path at large WMAN). The packer is
    // instantiated inside each branch so STAGE_NORMALIZE=0 feeds it the s3 results directly with no intermediate
    // alias net, keeping the default path structurally identical to a combinational normalize -> pack.
    generate
        if (STAGE_NORMALIZE == 0) begin : g_no_norm_register
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
        end else begin : g_norm_register
            reg                  r_valid;
            reg                  r_sign;
            reg                  r_force_zero;
            reg                  r_force_inf;
            reg signed [WEU-1:0] r_exp;
            reg       [WMAN-1:0] r_sig;
            reg                  r_guard;
            reg                  r_round;
            reg                  r_sticky;
            always @(posedge clk) begin
                if (rst) r_valid <= 1'b0;
                else     r_valid <= s3_valid;
                r_sign       <= s3_sign;
                r_force_zero <= s3_pack_force_zero;
                r_force_inf  <= s3_force_inf;
                r_exp        <= s3_pack_exp;
                r_sig        <= s3_pack_sig;
                r_guard      <= s3_pack_guard;
                r_round      <= s3_pack_round;
                r_sticky     <= s3_pack_sticky;
            end
            _zkf_pack #(
                .WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEU), .EXP_IS_BIASED(1), .STAGE_OUTPUT(STAGE_OUTPUT)
            ) u_pack (
                .clk(clk),
                .rst(rst),
                .in_valid(r_valid),
                .sign(r_sign),
                .force_zero(r_force_zero),
                .force_inf(r_force_inf),
                .exp_unbiased(r_exp),
                .significand(r_sig),
                .guard(r_guard),
                .round(r_round),
                .sticky(r_sticky),
                .out_valid(out_valid),
                .y(y)
            );
        end
    endgenerate

    // Stream pipeline. Reset clears only stream validity; payload registers free-run (s0b_valid is reset inside
    // its own generate block under STAGE_ALIGN). The capture is duplicated by STAGE_NORMALIZE depth so the <2 branch
    // is the exact single always block of the base design - byte-for-byte unchanged - while the ==2 branch threads
    // the s3-bound payload through one extra register (s2x_*) to realign it with the 3-segment normalizer, whose
    // outputs arrive one cycle later.
    generate
        if (STAGE_NORMALIZE < 2) begin : g_norm2_off
            always @(posedge clk) begin
                if (rst) begin
                    pr_valid <= 1'b0;
                    s0_valid <= 1'b0;
                    s1_valid <= 1'b0;
                    s2_valid <= 1'b0;
                    s3_valid <= 1'b0;
                end else begin
                    pr_valid <= mag_valid;
                    s0_valid <= d_valid;
                    s1_valid <= s0b_valid;
                    s2_valid <= s1_valid;
                    s3_valid <= s2_valid;
                end

        // Product stage capture.
        pr_product_norm <= mag_norm;
        pr_p_sign       <= m_p_sign;
        pr_p_zero       <= m_p_zero;
        pr_p_inf        <= m_p_inf;
        pr_ep_finite    <= mag_ep_finite;
        pr_c_sig        <= m_c_sig;
        pr_c_exp        <= m_c_exp;
        pr_c_sign       <= m_c_sign;
        pr_c_zero       <= m_c_zero;
        pr_c_inf        <= m_c_inf;

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

        // Stage 3 capture: add-path normalization (sub path lives in the normalizer's internal registers).
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
        end else begin : g_norm2_on
            reg                  s2x_valid;
            reg                  s2x_sign;
            reg                  s2x_same_sign;
            reg                  s2x_force_zero;
            reg                  s2x_force_inf;
            reg signed [WEU-1:0] s2x_anchor_exp;
            reg signed [WEU-1:0] s2x_add_exp;
            reg       [WMAN-1:0] s2x_add_sig;
            reg                  s2x_add_guard;
            reg                  s2x_add_round;
            reg                  s2x_add_sticky;
            always @(posedge clk) begin
                if (rst) begin
                    pr_valid  <= 1'b0;
                    s0_valid  <= 1'b0;
                    s1_valid  <= 1'b0;
                    s2_valid  <= 1'b0;
                    s2x_valid <= 1'b0;
                    s3_valid  <= 1'b0;
                end else begin
                    pr_valid  <= mag_valid;
                    s0_valid  <= d_valid;
                    s1_valid  <= s0b_valid;
                    s2_valid  <= s1_valid;
                    s2x_valid <= s2_valid;
                    s3_valid  <= s2x_valid;
                end

        // Product stage capture.
        pr_product_norm <= mag_norm;
        pr_p_sign       <= m_p_sign;
        pr_p_zero       <= m_p_zero;
        pr_p_inf        <= m_p_inf;
        pr_ep_finite    <= mag_ep_finite;
        pr_c_sig        <= m_c_sig;
        pr_c_exp        <= m_c_exp;
        pr_c_sign       <= m_c_sign;
        pr_c_zero       <= m_c_zero;
        pr_c_inf        <= m_c_inf;

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

                // Stage 2.5: realignment register between s2 and s3 (the 3-segment normalizer is +1 cycle).
                s2x_sign       <= s2_sign;
                s2x_same_sign  <= s2_same_sign;
                s2x_force_zero <= s2_force_zero;
                s2x_force_inf  <= s2_force_inf;
                s2x_anchor_exp <= s2_anchor_exp;
                s2x_add_exp    <= s2_add_exp;
                s2x_add_sig    <= s2_add_sig;
                s2x_add_guard  <= s2_add_guard;
                s2x_add_round  <= s2_add_round;
                s2x_add_sticky <= s2_add_sticky;

                // Stage 3 capture from the realignment register.
                s3_sign       <= s2x_sign;
                s3_same_sign  <= s2x_same_sign;
                s3_force_zero <= s2x_force_zero;
                s3_force_inf  <= s2x_force_inf;
                s3_anchor_exp <= s2x_anchor_exp;
                s3_add_exp    <= s2x_add_exp;
                s3_add_sig    <= s2x_add_sig;
                s3_add_guard  <= s2x_add_guard;
                s3_add_round  <= s2x_add_round;
                s3_add_sticky <= s2x_add_sticky;
            end
        end
    endgenerate
endmodule


`default_nettype none

// FMA-local 3-segment leading-zero normalizer for the wide cancellation path (STAGE_NORMALIZE=2). A radix-4 normalize
// (largest-shift-first), specialized to TWO internal register barriers - after the single coarsest level (whose
// near-full-width zero-detect is the widest) and at the midpoint - so the cascade closes in three short periods
// instead of two. Outputs (zero, count, y) are 2 cycles after x.
// Same y/count/zero contract as _zkf_normshift: count = applied left shift; count don't-care when zero.
module _zkf_fma_norm3 #(parameter W = 75, parameter WSHAMT = $clog2(W)) (
    input  wire              clk,
    input  wire      [W-1:0] x,
    output wire              zero,
    output wire [WSHAMT-1:0] count,
    output wire      [W-1:0] y
);
    localparam NL2         = $clog2(W);
    localparam NL4         = (NL2 + 1) / 2;        // radix-4 levels (NL4 >= 3 for the two barriers to be distinct)
    localparam CNTW        = 2 * NL4;
    localparam SPLIT_BACK  = (NL4 - 1) / 2;        // mid barrier (after this level)
    localparam SPLIT_FRONT = 0;                    // front barrier (after the coarsest level 0)

    // verilator coverage_off
    wire [W-1:0]    data     [0:NL4];
    wire [W-1:0]    data_pre [0:NL4];
    wire [CNTW-1:0] dig_pre;
    // verilator coverage_on
    assign data[0] = x;

    genvar s;
    generate
        for (s = 0; s < NL4; s = s + 1) begin : g_lvl
            localparam integer K = NL4 - 1 - s;
            localparam integer G = 1 << (2 * K);
            wire z1 = ~|data[s][W-1 -: G];
            wire z2;
            wire z3;
            if (2 * G < W) begin : g_z2  assign z2 = ~|data[s][W-1 -: (2 * G)]; end
            else           begin : g_z2z assign z2 = 1'b0;                      end
            if (3 * G < W) begin : g_z3  assign z3 = ~|data[s][W-1 -: (3 * G)]; end
            else           begin : g_z3z assign z3 = 1'b0;                      end
            assign dig_pre[2*K +: 2] = z1 ? (z2 ? (z3 ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
            // verilator coverage_off
            wire [W-1:0] sh1 = (G     < W) ? (data[s] << G)     : {W{1'b0}};
            wire [W-1:0] sh2 = (2 * G < W) ? (data[s] << (2*G)) : {W{1'b0}};
            wire [W-1:0] sh3 = (3 * G < W) ? (data[s] << (3*G)) : {W{1'b0}};
            assign data_pre[s+1] = z3 ? sh3 : (z2 ? sh2 : (z1 ? sh1 : data[s]));
            // verilator coverage_on
        end
    endgenerate

    // Two register barriers (after SPLIT_FRONT=0 and SPLIT_BACK); the data path accumulates both delays.
    genvar t;
    generate
        for (t = 1; t <= NL4; t = t + 1) begin : g_data
            if ((t == SPLIT_BACK + 1) || (t == SPLIT_FRONT + 1)) begin : g_split
                reg [W-1:0] data_r;
                always @(posedge clk) data_r <= data_pre[t];
                assign data[t] = data_r;
            end else begin : g_pass
                assign data[t] = data_pre[t];
            end
        end
    endgenerate
    assign y = data[NL4];

    // Count: a digit resolved at level s is delayed once per barrier ahead of it. Level-0 digit (resolved before
    // both barriers) gets two delays; levels 1..SPLIT_BACK get one; the rest none. This aligns count with y.
    // verilator coverage_off
    wire [CNTW-1:0] cnt;  // top count bits unreachable: leading-zero count <= W-1 < 2^(CNTW-1)
    // verilator coverage_on
    genvar k;
    generate
        for (k = 0; k < NL4; k = k + 1) begin : g_count
            if (k >= (NL4 - 1 - SPLIT_FRONT)) begin : g_d2
                reg [1:0] dig_r1, dig_r2;
                always @(posedge clk) begin dig_r1 <= dig_pre[2*k +: 2]; dig_r2 <= dig_r1; end
                assign cnt[2*k +: 2] = dig_r2;
            end else if (k >= (NL4 - 1 - SPLIT_BACK)) begin : g_d1
                reg [1:0] dig_r;
                always @(posedge clk) dig_r <= dig_pre[2*k +: 2];
                assign cnt[2*k +: 2] = dig_r;
            end else begin : g_d0
                assign cnt[2*k +: 2] = dig_pre[2*k +: 2];
            end
        end
    endgenerate

    reg zero_r1, zero_r2;
    always @(posedge clk) begin
        zero_r1 <= ~|x;
        zero_r2 <= zero_r1;
    end
    assign zero = zero_r2;

    generate
        if (WSHAMT > CNTW) begin : g_pad
            assign count = {{(WSHAMT-CNTW){1'b0}}, cnt};
        end else begin : g_no_pad
            assign count = cnt[WSHAMT-1:0];
        end
    endgenerate
endmodule

`default_nettype wire
