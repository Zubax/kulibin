/// Streamed Zubax Kulibin fused multiply-add: y = a*b + c.
/// The exact 2*WMAN-bit product is carried through alignment, add, and normalize, so a*b+c is rounded once.
/// That single rounding is the reason a true FMA is fundamentally wider than a chained zkf_mul -> zkf_add.
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
/// STAGE_NORMALIZE={0,1,2} adds exactly one register stage per unit (+STAGE_NORMALIZE cycles).
///
/// STAGE_PACK=0: packer reads its inputs combinationally (default).
/// STAGE_PACK=1: register the packer inputs (forwarded to _zkf_pack.STAGE_INPUT) (+1 cycle).
///
/// STAGE_OUTPUT=0: combinational packed output (default).
/// STAGE_OUTPUT=1: registered output (+1 cycle).

`default_nettype none

`define ZKF_FMA_LATENCY \
    (5 + STAGE_INPUT + STAGE_PRODUCT + STAGE_DECODE + STAGE_ALIGN + STAGE_NORMALIZE + STAGE_PACK + STAGE_OUTPUT)

module zkf_fma #(
    parameter WEXP            = 6,  // exponent field width
    parameter WMAN            = 18, // significand precision including the hidden bit
    parameter STAGE_INPUT     = 0,  // 0 = combinational inputs; 1 = latch inputs before any logic (+1 cycle)
    parameter STAGE_PRODUCT   = 0,  // 0 = combinational multiply; >=1 = split 2*2 product grid (+1 cycle)
    parameter STAGE_DECODE    = 0,  // 0 = decode feeds compare/select combinationally; 1 = register it (+1 cycle)
    parameter STAGE_ALIGN     = 0,  // 0 = single-cycle alignment; 1 = split alignment shifter (+1 cycle)
    parameter STAGE_NORMALIZE = 0,  // 0/1/2 internal normshift barriers (direct -> _zkf_normshift.STAGE_SPLIT)
    parameter STAGE_PACK      = 0,  // 0 = comb pack inputs; 1 = register pack inputs (+1 cycle)
    parameter STAGE_OUTPUT    = 0,  // 0 = combinational output; 1 = registered output (+1 cycle)
    parameter LATENCY         = `ZKF_FMA_LATENCY   // must equal the register-stage count; checked below
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
        if (LATENCY != `ZKF_FMA_LATENCY) begin : g_invalid_latency
            _zkf_invalid_latency_mismatch u_invalid();
        end
        // STAGE_INPUT / STAGE_DECODE / STAGE_PRODUCT are each realized locally as a single optional register, so only
        // {0,1} is meaningful. STAGE_ALIGN / STAGE_NORMALIZE / STAGE_PACK / STAGE_OUTPUT forward to their owners
        // (_zkf_rshift_sticky / _zkf_normshift / _zkf_pack), which validate their own ranges -- including
        // STAGE_NORMALIZE=2's "wide enough" requirement (_zkf_normshift's STAGE_SPLIT==2 && NL4<3 over the same
        // 2*WMAN+3 width rejects WMAN<7), so no normalize-vs-WMAN check is duplicated here.
        if ((STAGE_INPUT != 0) && (STAGE_INPUT != 1)) begin : g_invalid_stage_input
            _zkf_invalid_stage_input u_invalid();
        end
        if ((STAGE_DECODE != 0) && (STAGE_DECODE != 1)) begin : g_invalid_stage_decode
            _zkf_invalid_stage_decode u_invalid();
        end
        if ((STAGE_PRODUCT != 0) && (STAGE_PRODUCT != 1)) begin : g_invalid_stage_product
            _zkf_invalid_stage_product u_invalid();
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
    // Most-negative WEU value: any finite operand sorts above it, so a zero/non-finite operand (whose datapath
    // magnitude is forced to 0) is always selected as the "small" operand and contributes nothing.
    localparam signed [WEU-1:0] EXP_MIN = {1'b1, {(WEU-1){1'b0}}};

    // Optional input register stage: latch the operands before any combinational logic (+1 cycle when STAGE_INPUT=1).
    wire             in_valid_q;
    wire [WFULL-1:0] a_q;
    wire [WFULL-1:0] b_q;
    wire [WFULL-1:0] c_q;
    zkf_pipe #(.W(3*WFULL), .N(STAGE_INPUT ? 1 : 0)) u_input_pipe (
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
    // scans the FULL WF-bit magnitude (this full width is the irreducible cost of correct FMA rounding).
    // STAGE_NORMALIZE forwards directly to _zkf_normshift.STAGE_SPLIT (0/1/2 internal register barriers). For
    // SN=0 the cascade is combinational; the explicit s3-boundary register block below brings the outputs into
    // the s3 cycle. For SN=1 the normshift's internal register IS the s3 boundary (today's silent-SS=1 behavior).
    // For SN=2 the normshift has 2 internal stages and the s2x_* register block further below catches the add
    // path up to the same total delay.
    wire              norm_sub_zero;
    wire [WINDEX-1:0] norm_sub_shift;
    // verilator coverage_off
    wire     [WF-1:0] norm_sub_aligned;
    // verilator coverage_on
    _zkf_normshift #(.W(WF), .WSHAMT(WINDEX), .STAGE_SPLIT(STAGE_NORMALIZE)) u_sub_norm (
        .clk(clk),
        .x(s2_raw_result[WF-1:0]),
        .zero(norm_sub_zero),
        .count(norm_sub_shift),
        .y(norm_sub_aligned)
    );

    // The sub-path is ALWAYS registered at the s3 boundary. Total sub-path delay from s2 is STAGE_NORMALIZE + 1
    // (normshift internal + s3 register), matching the add-path's s2x (depth STAGE_NORMALIZE) + s3 register.
    reg               s3_sub_zero;
    reg  [WINDEX-1:0] s3_sub_shift;
    // verilator coverage_off
    reg      [WF-1:0] s3_sub_aligned;
    // verilator coverage_on
    always @(posedge clk) begin
        s3_sub_zero    <= norm_sub_zero;
        s3_sub_shift   <= norm_sub_shift;
        s3_sub_aligned <= norm_sub_aligned;
    end
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

    // Optional packer-input register (STAGE_PACK): splits the close-cancellation normalize + exponent correction
    // cone from the packer's rounding adder (the s3 critical path at large WMAN). The packer owns this register via
    // its STAGE_INPUT parameter; STAGE_PACK=0 keeps it disabled (default).
    _zkf_pack #(
        .WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEU), .EXP_IS_BIASED(1),
        .STAGE_INPUT(STAGE_PACK),
        .STAGE_OUTPUT(STAGE_OUTPUT)
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

    // Stream pipeline. Reset clears only stream validity; payload registers free-run (s0b_valid is reset inside its
    // own generate block under STAGE_ALIGN). The pr/s0/s1/s2 captures are unconditional; the add-path s2x catch-up
    // is a STAGE_NORMALIZE-deep register pipe that keeps the add path aligned with the normshift's internal
    // register cycles. STAGE_NORMALIZE=0 is a pure passthrough (no s2x registers); each unit adds 1 cycle.
    always @(posedge clk) begin
        if (rst) begin
            pr_valid <= 1'b0;
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
        end else begin
            pr_valid <= mag_valid;
            s0_valid <= d_valid;
            s1_valid <= s0b_valid;
            s2_valid <= s1_valid;
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
    end

    // Add-path s2x catch-up: a STAGE_NORMALIZE-deep register pipe that delays the s2 add-path signals so they
    // arrive at the s3 register boundary aligned with the sub-path's normshift internal register cycles.
    // Bundle: {sign, same_sign, force_zero, force_inf, anchor_exp, add_exp, add_sig, add_guard, add_round,
    // add_sticky}.
    localparam Q_W = 4 + 2*WEU + WMAN + 3;
    wire [Q_W-1:0] s2_q_in = {s2_sign, s2_same_sign, s2_force_zero, s2_force_inf,
                              s2_anchor_exp, s2_add_exp, s2_add_sig,
                              s2_add_guard, s2_add_round, s2_add_sticky};
    wire           q_valid;
    wire [Q_W-1:0] q_out;
    zkf_pipe #(.W(Q_W), .N(STAGE_NORMALIZE)) u_s2x (
        .clk(clk), .rst(rst),
        .in_valid(s2_valid), .in(s2_q_in),
        .out_valid(q_valid), .out(q_out)
    );
    wire                  q_sign         = q_out[Q_W-1];
    wire                  q_same_sign    = q_out[Q_W-2];
    wire                  q_force_zero   = q_out[Q_W-3];
    wire                  q_force_inf    = q_out[Q_W-4];
    wire signed [WEU-1:0] q_anchor_exp   = $signed(q_out[Q_W-5 -: WEU]);
    wire signed [WEU-1:0] q_add_exp      = $signed(q_out[Q_W-5-WEU -: WEU]);
    wire        [WMAN-1:0] q_add_sig     = q_out[Q_W-5-2*WEU -: WMAN];
    wire                  q_add_guard    = q_out[2];
    wire                  q_add_round    = q_out[1];
    wire                  q_add_sticky   = q_out[0];

    // Stage 3 register: captures from q_* (= s2 add-path delayed by STAGE_NORMALIZE cycles).
    always @(posedge clk) begin
        if (rst) s3_valid <= 1'b0;
        else     s3_valid <= q_valid;
        s3_sign       <= q_sign;
        s3_same_sign  <= q_same_sign;
        s3_force_zero <= q_force_zero;
        s3_force_inf  <= q_force_inf;
        s3_anchor_exp <= q_anchor_exp;
        s3_add_exp    <= q_add_exp;
        s3_add_sig    <= q_add_sig;
        s3_add_guard  <= q_add_guard;
        s3_add_round  <= q_add_round;
        s3_add_sticky <= q_add_sticky;
    end
endmodule

`undef ZKF_FMA_LATENCY
`default_nettype wire
