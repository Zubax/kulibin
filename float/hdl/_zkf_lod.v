/// Leading-one detector with shift-amount propagation, HI-priority.
///
/// Scans `x` (W bits) for the most significant set bit and returns:
///   - `zero`  : asserted iff x == 0.
///   - `shamt` : (W - 1) - position_of_leading_one, i.e. the left-shift count needed to bring
///               the leading 1 to the MSB (bit W-1). Don't-care when `zero` is asserted.
///
/// Tree-structured. Each internal node carries (valid, shamt) and picks HI when HI is valid; the
/// valid bits OR-reduce up the tree. `zero` is derived as `~|x` directly rather than read from
/// the tree root: ceil(log4(W)) LUT depth vs WIDX along the tree, same logical result.
///
/// WSHAMT defaults to $clog2(W); callers that need a wider output (e.g. when downstream signal
/// widths are sized off a different bound than W) can request padding via WSHAMT > $clog2(W).
///
/// Storage: a single flat 2D array (WIDX+1 rows of W slots) holds every per-level wire. Most
/// upper-level slots are unused — only ~2W of (WIDX+1)*W are driven — but Yosys's DCE removes
/// the undriven ones before mapping. A per-level scoped variant was tried and consistently lost
/// 2–7 MHz at fmax on the consumers (zkf_add, zkf_addsub) under both Yosys/nextpnr and Diamond,
/// so the flat representation is preferred even though it over-allocates source bits.

`default_nettype none

module _zkf_lod #(
    parameter W      = 32,
    parameter WSHAMT = $clog2(W)
) (
    input  wire         [W-1:0] x,
    output wire                 zero,
    output wire    [WSHAMT-1:0] shamt
);
    localparam WIDX = $clog2(W);

    wire [((WIDX + 1) * W)-1:0]        valid_stage;
    wire [((WIDX + 1) * W * WIDX)-1:0] shamt_stage;

    genvar i_leaf;
    genvar i_level;
    genvar i_node;
    generate
        for (i_leaf = 0; i_leaf < W; i_leaf = i_leaf + 1) begin : g_leaf
            localparam integer LEAF_SHIFT = W - 1 - i_leaf;
            assign valid_stage[i_leaf] = x[i_leaf];
            assign shamt_stage[i_leaf * WIDX +: WIDX] = LEAF_SHIFT[WIDX-1:0];
        end

        for (i_level = 0; i_level < WIDX; i_level = i_level + 1) begin : g_level
            localparam integer IN_COUNT  = (W + (1 << i_level) - 1) >> i_level;
            localparam integer OUT_COUNT = (IN_COUNT + 1) >> 1;
            for (i_node = 0; i_node < OUT_COUNT; i_node = i_node + 1) begin : g_node
                localparam integer OUT       = (i_level + 1) * W + i_node;
                localparam integer LO        = i_level * W + (2 * i_node);
                localparam integer HI        = LO + 1;
                localparam integer OUT_INDEX = OUT * WIDX;
                localparam integer LO_INDEX  = LO * WIDX;
                localparam integer HI_INDEX  = HI * WIDX;

                wire [WIDX-1:0] shamt_lo = shamt_stage[LO_INDEX +: WIDX];

                // Within a pair, HI corresponds to the higher (more significant) leaf and wins.
                if ((2 * i_node + 1) < IN_COUNT) begin : g_pair
                    wire [WIDX-1:0] shamt_hi = shamt_stage[HI_INDEX +: WIDX];
                    assign valid_stage[OUT] = valid_stage[LO] | valid_stage[HI];
                    assign shamt_stage[OUT_INDEX +: WIDX] = valid_stage[HI] ? shamt_hi : shamt_lo;
                end else begin : g_odd
                    assign valid_stage[OUT] = valid_stage[LO];
                    assign shamt_stage[OUT_INDEX +: WIDX] = shamt_lo;
                end
            end
        end
    endgenerate

    wire [WIDX-1:0] shamt_root = shamt_stage[(WIDX * W * WIDX) +: WIDX];

    assign zero  = ~|x;
    generate
        if (WSHAMT > WIDX) begin : g_pad
            assign shamt = {{(WSHAMT-WIDX){1'b0}}, shamt_root};
        end else begin : g_no_pad
            assign shamt = shamt_root;
        end
    endgenerate
endmodule

`default_nettype wire
