/// Leading-zero-normalizing left shifter: brings the most significant set bit of `x` up to the MSB (bit W-1) and
/// reports how far it had to shift. Outputs:
///   - `zero`  : asserted iff x == 0.
///   - `count` : (W-1) - position_of_leading_one, i.e. the applied left-shift amount. Don't-care when `zero`.
///   - `y`     : x << count, the normalized vector (leading 1 at bit W-1 for nonzero x).
///
/// This fuses what used to be a separate leading-one detector (_zkf_lod) followed by a separate barrel shift: the
/// same mux cascade that tests-and-shifts also yields the count as the concatenation of its per-level digits, roughly
/// halving the multiplexer footprint of the count-then-shift pair. Modelled on FloPoCo's Normalizer_Z. Used by the
/// adder's close-cancellation normalization and by the integer-to-float magnitude normalization.
///
/// Implementation: radix-4 cascade, processed largest-shift first, so the depth is half the radix-2 equivalent (which
/// matters for timing closure at wide W). Level k (weight G = 4^k) inspects the top G, 2G and 3G bits; the number of
/// all-zero leading G-groups (0..3) is the radix-4 digit, the data is shifted left by digit*G, and the digit is the
/// count's base-4 place k. Groups/shifts beyond W are clamped at elaboration (only ever selected for x == 0, whose
/// count is don't-care). Walking high-to-low brings the leading one to the MSB and assembles count = {digits}.
///
/// WSHAMT defaults to clog2(W); callers needing a wider count (downstream widths sized off a different bound) may
/// request WSHAMT > clog2(W) and the count is zero-padded. The internal radix-4 count is 2*ceil(clog2(W)/2) bits and
/// is truncated to WSHAMT; this is lossless because count <= W-1 < 2^clog2(W) <= 2^WSHAMT for every nonzero input.
///
/// STAGE_SPLIT=0: pure combinational, single-cycle (clk unused).
/// STAGE_SPLIT=1: one register barrier in the middle of the cascade; y/count/zero appear one cycle after x, and the
/// consumer must add a matching cycle to its pipeline. The early (pre-barrier) digits and zero are delayed one cycle
/// so the whole count and zero stay aligned with the late digits and the shifted output (cf. FloPoCo's *_d1).

`default_nettype none

module _zkf_normshift #(
    parameter W           = 16,
    parameter WSHAMT      = $clog2(W),
    parameter STAGE_SPLIT = 0
) (
    input  wire              clk,    // unused when STAGE_SPLIT == 0
    input  wire      [W-1:0] x,
    output wire              zero,
    output wire [WSHAMT-1:0] count,
    output wire      [W-1:0] y
);
    localparam NL2         = $clog2(W);     // radix-2 levels that would be needed
    localparam NL4         = (NL2 + 1) / 2; // radix-4 levels (two count bits each)
    localparam CNTW        = 2 * NL4;       // internal count width
    // Register barrier sits after radix-4 level SPLIT_AFTER (only used when STAGE_SPLIT != 0). The front (pre-barrier)
    // levels do the larger shifts with the wider zero-detect OR-reductions; the consumer's back cone also carries the
    // count assembly and exponent arithmetic. (NL4-1)/2 keeps the front from one level too deep at wide W.
    localparam SPLIT_AFTER = (NL4 - 1) / 2;

    // data[s] is the input to radix-4 level s; data[0] = x, data[NL4] = normalized output.
    // verilator coverage_off
    // The cascade arrays are over-provisioned and many shifted-in pad bits are structurally constant; behaviour is
    // checked end-to-end through y/count/zero by the normshift bench and every caller, so toggling is suppressed here.
    wire [W-1:0]    data     [0:NL4];
    wire [W-1:0]    data_pre [0:NL4];   // index 0 unused
    wire [CNTW-1:0] dig_pre;            // combinational per-level radix-4 digits, digit k at bits [2k+1:2k]
    // verilator coverage_on
    assign data[0] = x;

    genvar s;
    generate
        for (s = 0; s < NL4; s = s + 1) begin : g_lvl
            localparam integer K   = NL4 - 1 - s;      // this level resolves count digit K (weight 4^K)
            localparam integer G   = 1 << (2 * K);     // 4^K
            // Zero-detect group widths and shift distances, clamped to W (groups/shifts past W only matter for x==0).
            localparam integer G1  = (G     < W) ? G     : W;
            localparam integer G2  = (2 * G  < W) ? 2 * G : W;
            localparam integer G3  = (3 * G  < W) ? 3 * G : W;

            wire z1 = ~|data[s][W-1 -: G1];   // top G bits all zero  -> shift at least G
            wire z2 = ~|data[s][W-1 -: G2];   // top 2G bits all zero -> shift at least 2G
            wire z3 = ~|data[s][W-1 -: G3];   // top 3G bits all zero -> shift 3G
            // Radix-4 digit: number of all-zero leading G-groups (z3 => z2 => z1), 0..3.
            wire [1:0] dig = z1 ? (z2 ? (z3 ? 2'd3 : 2'd2) : 2'd1) : 2'd0;
            assign dig_pre[2*K +: 2] = dig;

            // verilator coverage_off
            // Shift candidates; those that would over-shift past W are constant 0 and only selectable for x==0.
            wire [W-1:0] sh1 = (G     < W) ? (data[s] << G)     : {W{1'b0}};
            wire [W-1:0] sh2 = (2 * G < W) ? (data[s] << (2*G)) : {W{1'b0}};
            wire [W-1:0] sh3 = (3 * G < W) ? (data[s] << (3*G)) : {W{1'b0}};
            assign data_pre[s+1] = (dig == 2'd0) ? data[s]
                                 : (dig == 2'd1) ? sh1
                                 : (dig == 2'd2) ? sh2
                                 :                 sh3;
            // verilator coverage_on
        end
    endgenerate

    // Wire data[s] from the per-level combinational outputs; insert the register barrier at index SPLIT_AFTER+1 when
    // STAGE_SPLIT != 0, breaking the cascade into two clock periods.
    genvar t;
    generate
        for (t = 1; t <= NL4; t = t + 1) begin : g_data
            if ((STAGE_SPLIT != 0) && (t == SPLIT_AFTER + 1)) begin : g_split
                reg [W-1:0] data_r;
                always @(posedge clk) data_r <= data_pre[t];
                assign data[t] = data_r;
            end else begin : g_pass
                assign data[t] = data_pre[t];
            end
        end
    endgenerate

    assign y = data[NL4];

    // Count assembly. When STAGE_SPLIT != 0 the digits resolved before the barrier (levels s <= SPLIT_AFTER, i.e.
    // digits K >= NL4-1-SPLIT_AFTER) are computed a cycle early, so register them to line up with the late digits
    // (computed from the registered data) and with y. zero is likewise delayed so force-zero stays aligned.
    wire [CNTW-1:0] cnt;
    genvar k;
    generate
        for (k = 0; k < NL4; k = k + 1) begin : g_count
            if ((STAGE_SPLIT != 0) && (k >= (NL4 - 1 - SPLIT_AFTER))) begin : g_count_delay
                reg [1:0] dig_r;
                always @(posedge clk) dig_r <= dig_pre[2*k +: 2];
                assign cnt[2*k +: 2] = dig_r;
            end else begin : g_count_pass
                assign cnt[2*k +: 2] = dig_pre[2*k +: 2];
            end
        end
    endgenerate

    wire zero_pre = ~|x;
    generate
        if (STAGE_SPLIT != 0) begin : g_zero_delay
            reg zero_r;
            always @(posedge clk) zero_r <= zero_pre;
            assign zero = zero_r;
        end else begin : g_zero_pass
            assign zero = zero_pre;
        end
    endgenerate

    generate
        if (WSHAMT > CNTW) begin : g_pad
            assign count = {{(WSHAMT-CNTW){1'b0}}, cnt};
        end else begin : g_no_pad
            assign count = cnt[WSHAMT-1:0];
        end
    endgenerate
endmodule

`default_nettype wire
