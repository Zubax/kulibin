/// Fixed-point Horner polynomial evaluator for the transcendental table+polynomial cores.
/// Register stages: D*(2+STAGE_PRODUCT).
/// Zero-bubble, throughput-1. A generic sideband (sb_in -> sb_out) and the valid flag are pipelined
/// alongside the accumulator so the instantiating module need not know D.
///
/// Computes acc = c[D]; then for j = D-1 .. 0: acc = c[j] + floor(acc * w / 2^RW), i.e. Horner in the segment-local
/// argument wn = w / 2^RW in [0,1). Coefficients share the fractional scale 2^-CF: c[j] is a signed CW-bit value at
/// bit offset j*CW of the flat `coeffs` bus. The arithmetic right shift `>>> RW` floors toward minus infinity,
/// matching the Python reference model's truncating integer Horner exactly.
///
/// STAGE_PRODUCT selects the multiply implementation and the number of extra register stages per degree:
///
///   STAGE_PRODUCT=0: 2 register stages per degree (one multiply, then shift + coefficient-add). Multiply is one `*`.
///
///   STAGE_PRODUCT=1: 3 register stages per degree. The multiply is the 2x2 product grid of half-width operands
///                    (acc*w = acc_hi*w_hi<<(WALO+WWLO) + acc_hi*w_lo<<WALO + acc_lo*w_hi<<WWLO + acc_lo*w_lo),
///                    registered, then summed in a dedicated stage. Requires RW >= 2.
///
///   STAGE_PRODUCT=2: 4 register stages per degree. Same 2x2 product grid as STAGE_PRODUCT=1, with an operand-capture
///                    register before each multiply so the placer can arrange the registers around the DSP/sub-product
///                    chain independently from the preceding coefficient-add stage.
///
///   STAGE_PRODUCT=3: 5 register stages per degree. The multiply is a 3x3 product grid of third-width operands, with
///                    an operand-capture register before each multiply. The 9 sub-products are registered, then summed
///                    row-by-acc-chunk into 3 row sums (registered), then those 3 are combined into the full product
///                    (registered). For very wide operands this lets each sub-product map to a single small multiplier
///                    whose output register packs into the DSP, and keeps every adder in the sum tree shallow. Requires
///                    RW >= 3, ACCW >= 3.
///
/// The 3x3 implementation without the operand-capture stage is intentionally not exposed because the extra stage is
/// the timing-closure reason to use that larger split.
///
/// ACCW must hold every intermediate `acc` without wrap (the generator sizes it from the actual coefficient set).
/// Reset clears only the valid pipeline; the datapath registers free-run (project reset strategy).

`default_nettype none

module _zkf_horner #(
    parameter integer D             = 2,  // polynomial degree (D+1 coefficients), >= 1
    parameter integer CW            = 32, // signed coefficient width
    parameter integer RW            = 8,  // reduced-argument width; wn = w / 2^RW
    parameter integer ACCW          = 40, // signed accumulator width (>= every intermediate, sized by the generator)
    parameter integer SBW           = 1,  // sideband width carried alongside the pipeline
    parameter integer STAGE_PRODUCT = 0   // see above
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    in_valid,
    input  wire        [SBW-1:0]   sb_in,
    // coeffs and acc are fixed-point carriers whose top bits are structural headroom: every coefficient is a small
    // signed value padded to CW (sign + margin), and acc holds 2**f in [1,2) (exp2) or P(t) in [1,1/ln2] (log2) at
    // scale 2**CF, so its bits above CF never toggle for any input. Their meaningful bits are exercised end-to-end by
    // the exp2/log2 suites; suppress these carriers from the toggle gate (no single format can toggle every bit).
    // verilator coverage_off
    input  wire [(D+1)*CW-1:0]     coeffs,   // c[j] (signed) at bits [j*CW +: CW], j = 0..D
    // verilator coverage_on
    input  wire        [RW-1:0]    w,        // reduced argument, unsigned, in [0, 2^RW)
    output wire                    out_valid,
    output wire        [SBW-1:0]   sb_out,
    // verilator coverage_off
    output wire signed [ACCW-1:0]  acc       // Horner result, signed, scale 2^-CF
    // verilator coverage_on
);
    // verilator coverage_off
    generate
        if (((STAGE_PRODUCT == 1) || (STAGE_PRODUCT == 2)) && (RW < 2)) begin : g_invalid_split2
            _zkf_invalid_stage_product_needs_rw2 u_invalid();
        end
        if ((STAGE_PRODUCT == 3) && ((RW < 3) || (ACCW < 3))) begin : g_invalid_split3
            _zkf_invalid_stage_product2_needs_rw3_accw3 u_invalid();
        end
        if ((STAGE_PRODUCT < 0) || (STAGE_PRODUCT > 3)) begin : g_invalid_stage_product
            _zkf_invalid_stage_product_out_of_range u_invalid();
        end
    endgenerate
    // verilator coverage_on

    // Half-width operand pieces for the STAGE_PRODUCT=1 grid (sized off W/2, not the DSP width).
    localparam integer WALO = (ACCW + 1) / 2;
    localparam integer WAHI = ACCW - WALO;
    localparam integer WWLO = (RW + 1) / 2;
    localparam integer WWHI = (RW > WWLO) ? (RW - WWLO) : 1;
    // Third-width operand pieces for the STAGE_PRODUCT=3 grid. The two low chunks are unsigned; the top chunk carries
    // the sign. Sizes are deliberately balanced (low + mid + high == ACCW/RW exactly).
    localparam integer WA0 = (ACCW + 2) / 3;
    localparam integer WA1 = (ACCW + 1) / 3;
    localparam integer WA2 = (ACCW - WA0 - WA1 > 0) ? (ACCW - WA0 - WA1) : 1;
    localparam integer WW0 = (RW + 2) / 3;
    localparam integer WW1 = (RW + 1) / 3;
    localparam integer WW2 = (RW - WW0 - WW1 > 0) ? (RW - WW0 - WW1) : 1;

    // verilator coverage_off
    // a_*[s] is the state entering degree step s (s = 0..D); arrays sized for the max degree across configs and the
    // high accumulator bits are structural headroom proven not to wrap. Checked end to end via the eval cores.
    wire signed [ACCW-1:0]    a_acc [0:D];
    wire [(D+1)*CW-1:0]       a_co  [0:D];
    wire [RW-1:0]             a_w   [0:D];
    wire                      a_val [0:D];
    wire [SBW-1:0]            a_sb  [0:D];
    // verilator coverage_on

    assign a_acc[0] = $signed(coeffs[D*CW +: CW]);  // acc starts at the top coefficient c[D]
    assign a_co[0]  = coeffs;
    assign a_w[0]   = w;
    assign a_val[0] = in_valid;
    assign a_sb[0]  = sb_in;

    genvar s;
    generate
        for (s = 0; s < D; s = s + 1) begin : g_step
            localparam integer J = D - 1 - s;  // coefficient index resolved at this step
            // Coefficients are consumed in strictly descending index order (J = D-1, D-2, ... , 0), so entering
            // step s only c[0..J] are still live: carry just the low (J+1)*CW bits, MSB-aligned to keep the
            // `[J*CW +: CW]` read at the top of the slice. c[D] already seeded a_acc[0] and is never carried.
            // This tapers the coefficient pipeline to ~half the FFs of a full-width carry; a_co[s+1] zero-extends
            // the narrow forward into the uniform wiring array, and the next step slices off what it needs.
            localparam integer COW = (J + 1) * CW;

            wire signed [ACCW-1:0] p_acc;
            wire        [COW-1:0]  p_co;
            wire        [RW-1:0]   p_w;
            wire                   p_val;
            wire        [SBW-1:0]  p_sb;
            if ((STAGE_PRODUCT == 2) || (STAGE_PRODUCT == 3)) begin : g_product_input_stage
                reg signed [ACCW-1:0] i_acc;
                reg        [COW-1:0]  i_co;
                reg        [RW-1:0]   i_w;
                reg                   i_val;
                reg        [SBW-1:0]  i_sb;
                always @(posedge clk) begin
                    if (rst) i_val <= 1'b0;
                    else     i_val <= a_val[s];
                    i_acc <= a_acc[s];
                    i_co  <= a_co[s][COW-1:0];
                    i_w   <= a_w[s];
                    i_sb  <= a_sb[s];
                end
                assign p_acc = i_acc;
                assign p_co  = i_co;
                assign p_w   = i_w;
                assign p_val = i_val;
                assign p_sb  = i_sb;
            end else begin : g_product_input_direct
                assign p_acc = a_acc[s];
                assign p_co  = a_co[s][COW-1:0];
                assign p_w   = a_w[s];
                assign p_val = a_val[s];
                assign p_sb  = a_sb[s];
            end

            if (STAGE_PRODUCT == 0) begin : g_single
                // -- Multiply stage: single product, registered. --
                reg signed [ACCW+RW:0] m_prod;
                reg [COW-1:0]          m_co;
                reg [RW-1:0]           m_w;
                reg                    m_val;
                reg [SBW-1:0]          m_sb;
                always @(posedge clk) begin
                    if (rst) m_val <= 1'b0;
                    else     m_val <= p_val;
                    m_prod <= p_acc * $signed({1'b0, p_w});
                    m_co   <= p_co;
                    m_w    <= p_w;
                    m_sb   <= p_sb;
                end
                // -- Coefficient-add stage. --
                wire signed [ACCW-1:0] next_acc = $signed(m_co[J*CW +: CW]) + $signed(m_prod >>> RW);
                reg signed [ACCW-1:0] r_acc;
                reg [COW-1:0]         r_co;
                reg [RW-1:0]          r_w;
                reg                   r_val;
                reg [SBW-1:0]         r_sb;
                always @(posedge clk) begin
                    if (rst) r_val <= 1'b0;
                    else     r_val <= m_val;
                    r_acc <= next_acc;
                    r_co  <= m_co;
                    r_w   <= m_w;
                    r_sb  <= m_sb;
                end
                assign a_acc[s + 1] = r_acc;
                assign a_co[s + 1]  = r_co;
                assign a_w[s + 1]   = r_w;
                assign a_val[s + 1] = r_val;
                assign a_sb[s + 1]  = r_sb;
            end else if ((STAGE_PRODUCT == 1) || (STAGE_PRODUCT == 2)) begin : g_split
                // -- Multiply stage: 2x2 grid of half-width products, registered. --
                wire        [WALO-1:0]     acc_lo = p_acc[WALO-1:0];
                wire signed [WAHI-1:0]     acc_hi = p_acc[ACCW-1:WALO];
                wire        [WWLO-1:0]     w_lo   = p_w[WWLO-1:0];
                wire        [WWHI-1:0]     w_hi   = p_w[RW-1:WWLO];
                wire        [WALO+WWLO-1:0] p_ll = acc_lo * w_lo;
                wire        [WALO+WWHI-1:0] p_lh = acc_lo * w_hi;
                wire signed [WAHI+WWLO:0]   p_hl = acc_hi * $signed({1'b0, w_lo});
                wire signed [WAHI+WWHI:0]   p_hh = acc_hi * $signed({1'b0, w_hi});
                reg         [WALO+WWLO-1:0] m_p_ll;
                reg         [WALO+WWHI-1:0] m_p_lh;
                reg signed  [WAHI+WWLO:0]   m_p_hl;
                reg signed  [WAHI+WWHI:0]   m_p_hh;
                reg [COW-1:0]      m_co;
                reg [RW-1:0]       m_w;
                reg                m_val;
                reg [SBW-1:0]      m_sb;
                always @(posedge clk) begin
                    if (rst) m_val <= 1'b0;
                    else     m_val <= p_val;
                    m_p_ll <= p_ll;
                    m_p_lh <= p_lh;
                    m_p_hl <= p_hl;
                    m_p_hh <= p_hh;
                    m_co   <= p_co;
                    m_w    <= p_w;
                    m_sb   <= p_sb;
                end
                // -- Sum stage: combine the partial products, registered. --
                wire signed [ACCW+RW:0] prod = ($signed(m_p_hh)         <<< (WALO + WWLO))
                                             + ($signed(m_p_hl)         <<< WALO)
                                             + ($signed({1'b0, m_p_lh}) <<< WWLO)
                                             +   $signed({1'b0, m_p_ll});
                reg signed [ACCW+RW:0] s_prod;
                reg [COW-1:0]          s_co;
                reg [RW-1:0]           s_w;
                reg                    s_val;
                reg [SBW-1:0]          s_sb;
                always @(posedge clk) begin
                    if (rst) s_val <= 1'b0;
                    else     s_val <= m_val;
                    s_prod <= prod;
                    s_co   <= m_co;
                    s_w    <= m_w;
                    s_sb   <= m_sb;
                end
                // -- Coefficient-add stage. --
                wire signed [ACCW-1:0] next_acc = $signed(s_co[J*CW +: CW]) + $signed(s_prod >>> RW);
                reg signed [ACCW-1:0] r_acc;
                reg [COW-1:0]         r_co;
                reg [RW-1:0]          r_w;
                reg                   r_val;
                reg [SBW-1:0]         r_sb;
                always @(posedge clk) begin
                    if (rst) r_val <= 1'b0;
                    else     r_val <= s_val;
                    r_acc <= next_acc;
                    r_co  <= s_co;
                    r_w   <= s_w;
                    r_sb  <= s_sb;
                end
                assign a_acc[s + 1] = r_acc;
                assign a_co[s + 1]  = r_co;
                assign a_w[s + 1]   = r_w;
                assign a_val[s + 1] = r_val;
                assign a_sb[s + 1]  = r_sb;
            end else if (STAGE_PRODUCT == 3) begin : g_split3
                // -- STAGE_PRODUCT=3: 3x3 grid of third-width sub-products, registered (single-DSP-friendly at very
                //    wide WMAN), summed row-by-acc-chunk into 3 row sums (Stage 2), then those 3 are combined into the
                //    full product (Stage 3). Stage 4 is the coefficient add. 4 register stages per degree.
                //    Top acc chunk a2 is signed; the two low acc chunks and all three w chunks are unsigned.
                wire        [WA0-1:0] a0 = p_acc[WA0-1:0];
                wire        [WA1-1:0] a1 = p_acc[WA0+WA1-1:WA0];
                wire signed [WA2-1:0] a2 = p_acc[ACCW-1:WA0+WA1];
                wire        [WW0-1:0] b0 = p_w[WW0-1:0];
                wire        [WW1-1:0] b1 = p_w[WW0+WW1-1:WW0];
                wire        [WW2-1:0] b2 = p_w[RW-1:WW0+WW1];
                // Sub-products: signed = signed (a2) * zero-extended unsigned. Width of a2*bj is WA2+WWj+1 bits.
                wire        [WA0+WW0-1:0] p00 = a0 * b0;
                wire        [WA0+WW1-1:0] p01 = a0 * b1;
                wire        [WA0+WW2-1:0] p02 = a0 * b2;
                wire        [WA1+WW0-1:0] p10 = a1 * b0;
                wire        [WA1+WW1-1:0] p11 = a1 * b1;
                wire        [WA1+WW2-1:0] p12 = a1 * b2;
                wire signed [WA2+WW0:0]   p20 = a2 * $signed({1'b0, b0});
                wire signed [WA2+WW1:0]   p21 = a2 * $signed({1'b0, b1});
                wire signed [WA2+WW2:0]   p22 = a2 * $signed({1'b0, b2});
                // -- Stage 1: register the 9 sub-products. --
                reg [WA0+WW0-1:0] m_p00;
                reg [WA0+WW1-1:0] m_p01;
                reg [WA0+WW2-1:0] m_p02;
                reg [WA1+WW0-1:0] m_p10;
                reg [WA1+WW1-1:0] m_p11;
                reg [WA1+WW2-1:0] m_p12;
                reg signed [WA2+WW0:0] m_p20;
                reg signed [WA2+WW1:0] m_p21;
                reg signed [WA2+WW2:0] m_p22;
                reg [COW-1:0]     m_co;
                reg [RW-1:0]      m_w;
                reg               m_val;
                reg [SBW-1:0]     m_sb;
                always @(posedge clk) begin
                    if (rst) m_val <= 1'b0;
                    else     m_val <= p_val;
                    m_p00 <= p00; m_p01 <= p01; m_p02 <= p02;
                    m_p10 <= p10; m_p11 <= p11; m_p12 <= p12;
                    m_p20 <= p20; m_p21 <= p21; m_p22 <= p22;
                    m_co  <= p_co;
                    m_w   <= p_w;
                    m_sb  <= p_sb;
                end
                // -- Stage 2: per-acc-chunk row sums (each row sums 3 sub-products with w-chunk shifts <= RW). The
                //    two low rows are unsigned (zero-extend); the top row is signed (a2 carries the sign). --
                wire signed [ACCW+RW:0] row0 = ($signed({1'b0, m_p02}) <<< (WW0 + WW1))
                                              + ($signed({1'b0, m_p01}) <<< WW0)
                                              +   $signed({1'b0, m_p00});
                wire signed [ACCW+RW:0] row1 = ($signed({1'b0, m_p12}) <<< (WW0 + WW1))
                                              + ($signed({1'b0, m_p11}) <<< WW0)
                                              +   $signed({1'b0, m_p10});
                wire signed [ACCW+RW:0] row2 = ($signed(m_p22)         <<< (WW0 + WW1))
                                              + ($signed(m_p21)         <<< WW0)
                                              +   $signed(m_p20);
                reg signed [ACCW+RW:0] s_row0, s_row1, s_row2;
                reg [COW-1:0]          s_co;
                reg [RW-1:0]           s_w;
                reg                    s_val;
                reg [SBW-1:0]          s_sb;
                always @(posedge clk) begin
                    if (rst) s_val <= 1'b0;
                    else     s_val <= m_val;
                    s_row0 <= row0;
                    s_row1 <= row1;
                    s_row2 <= row2;
                    s_co   <= m_co;
                    s_w    <= m_w;
                    s_sb   <= m_sb;
                end
                // -- Stage 3: combine the three row sums with acc-chunk shifts into the full product. --
                wire signed [ACCW+RW:0] prod3 = (s_row2 <<< (WA0 + WA1)) + (s_row1 <<< WA0) + s_row0;
                reg signed [ACCW+RW:0] t_prod;
                reg [COW-1:0]          t_co;
                reg [RW-1:0]           t_w;
                reg                    t_val;
                reg [SBW-1:0]          t_sb;
                always @(posedge clk) begin
                    if (rst) t_val <= 1'b0;
                    else     t_val <= s_val;
                    t_prod <= prod3;
                    t_co   <= s_co;
                    t_w    <= s_w;
                    t_sb   <= s_sb;
                end
                // -- Stage 4: coefficient-add. --
                wire signed [ACCW-1:0] next_acc3 = $signed(t_co[J*CW +: CW]) + $signed(t_prod >>> RW);
                reg signed [ACCW-1:0] r_acc;
                reg [COW-1:0]         r_co;
                reg [RW-1:0]          r_w;
                reg                   r_val;
                reg [SBW-1:0]         r_sb;
                always @(posedge clk) begin
                    if (rst) r_val <= 1'b0;
                    else     r_val <= t_val;
                    r_acc <= next_acc3;
                    r_co  <= t_co;
                    r_w   <= t_w;
                    r_sb  <= t_sb;
                end
                assign a_acc[s + 1] = r_acc;
                assign a_co[s + 1]  = r_co;
                assign a_w[s + 1]   = r_w;
                assign a_val[s + 1] = r_val;
                assign a_sb[s + 1]  = r_sb;
            end else begin : g_invalid
                assign a_acc[s + 1] = a_acc[s];
                assign a_co[s + 1]  = a_co[s];
                assign a_w[s + 1]   = a_w[s];
                assign a_val[s + 1] = a_val[s];
                assign a_sb[s + 1]  = a_sb[s];
            end
        end
    endgenerate

    assign acc       = a_acc[D];
    assign out_valid = a_val[D];
    assign sb_out    = a_sb[D];
endmodule

`default_nettype wire
