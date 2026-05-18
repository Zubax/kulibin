/// Streamed cast from signed two's-complement integer to Zubax Kulibin float.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Register stages: 3 end-to-end.

`default_nettype none

module zkf_from_int #(
    parameter WEXP = 6,
    parameter WMAN = 18,
    parameter WINT = 32
) (
    input wire clk,
    input wire rst,

    input wire                   in_valid,
    input wire signed [WINT-1:0] a,

    output wire                  out_valid,
    output wire [WEXP+WMAN-1:0]  y
);
    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4) || (WINT < 2)) begin : g_invalid
            _zkf_invalid_wexp_or_wman u_invalid();
        end
    endgenerate
    // verilator coverage_on

    // Magnitude container width: must be at least WINT (to hold |a|, including |INT_MIN| = 2^(WINT-1))
    // and at least WMAN+3 so a static slice of [WX-WMAN-3:0] always provides at least one sticky bit.
    localparam WX    = (WINT > (WMAN + 3)) ? WINT : (WMAN + 3);
    localparam WIDX  = $clog2(WX);
    // Unbiased exponent must hold the maximum leading-one position (WX-1) and _zkf_pack's own internal range that
    // needs at least WEXP+2 signed bits.
    localparam WEU_LOD = WIDX + 1;
    localparam WEU     = (WEU_LOD > (WEXP + 2)) ? WEU_LOD : (WEXP + 2);

    // Absolute value via XOR-and-increment so the path uses the carry chain; this also handles INT_MIN correctly
    // because the resulting unsigned magnitude 2^(WINT-1) fits in WINT bits. Compute the leading-one position
    // pre-stage-1 so the heavy LOD tree sits on the input cone rather than chaining behind the magnitude register;
    // that splits the long LOD->shift->pack path across two cycles without burning an extra pipeline stage.
    wire            sign_in    = a[WINT-1];
    wire [WINT-1:0] inv_in     = a ^ {WINT{sign_in}};
    wire [WINT-1:0] mag_in     = inv_in + {{(WINT-1){1'b0}}, sign_in};
    wire [WX-1:0]   mag_ext_in = {{(WX-WINT){1'b0}}, mag_in};

    wire            zero_in;
    wire [WIDX-1:0] shamt_in;
    _zkf_from_int_lod #(.W(WX)) u_lod (.x(mag_ext_in), .zero(zero_in), .shamt(shamt_in));

    // Stage 1: register sign, magnitude, and the pre-computed LOD outputs. Reset only validity; payload free-runs.
    reg            s1_valid;
    reg            s1_sign;
    reg [WX-1:0]   s1_mag_ext;
    reg            s1_zero;
    reg [WIDX-1:0] s1_shamt;

    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= in_valid;
        end
        s1_sign    <= sign_in;
        s1_mag_ext <= mag_ext_in;
        s1_zero    <= zero_in;
        s1_shamt   <= shamt_in;
    end

    // Stage 1 -> Stage 2 combinational: barrel shift (LOD already done) plus GRS extraction and exponent derivation.
    // Significand carries the hidden leading 1 at the top; the next two bits feed guard/round, and any remaining bits
    // below OR-reduce into sticky.
    wire   [WX-1:0] s1_aligned     = s1_mag_ext << s1_shamt;
    wire [WMAN-1:0] s1_significand =  s1_aligned[WX-1 -: WMAN];
    wire            s1_guard       =  s1_aligned[WX-WMAN-1];
    wire            s1_round       =  s1_aligned[WX-WMAN-2];
    wire            s1_sticky      = |s1_aligned[WX-WMAN-3:0];

    // exp_unbiased = position of the leading 1 = (WX-1) - shamt. The subtraction sits on the carry chain and is the
    // same shape as the bias subtraction inside _zkf_pack, avoiding a separate comparator.
    //
    // Invariant: shamt is in [0, WX-1] for every input, including all-zero.
    // The LOD's leaves store LEAF_SHIFT = WX-1-i in [0, WX-1] and the tree only propagates leaf values (no arithmetic),
    // so the root shamt is always a leaf value. The subtraction below therefore never underflows; zero-extending into
    // s1_exp_ub is safe and does not need sign extension. For all-zero magnitude in particular, shamt = WX-1 produces
    // s1_exp_ub = 0, but _zkf_pack ignores exp_unbiased when force_zero (= s1_zero) is asserted.
    wire        [WIDX:0]  s1_top_ext   = WX - 1;
    wire        [WIDX:0]  s1_shamt_ext = {1'b0, s1_shamt};
    wire        [WIDX:0]  s1_pos_ext   = s1_top_ext - s1_shamt_ext;
    wire signed [WEU-1:0] s1_exp_ub    = {{(WEU-WIDX-1){1'b0}}, s1_pos_ext};

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEU)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s1_valid),
        .sign(s1_sign),
        .force_zero(s1_zero),
        .force_inf(1'b0),
        .exp_unbiased(s1_exp_ub),
        .significand(s1_significand),
        .guard(s1_guard),
        .round(s1_round),
        .sticky(s1_sticky),
        .out_valid(out_valid),
        .y(y)
    );
endmodule


// Leading-one detector. Returns `shamt = (W-1) - leading_one_position` so the consuming
// barrel shifter can apply it directly, and a `zero` flag for all-zero inputs (shamt is
// don't-care in that case). Tree-structured to keep the depth at log2(W); the convention
// matches `_zkf_add_sub_shift_count` so a future reviewer recognises the pattern.
module _zkf_from_int_lod #(parameter W = 32) (
    input  wire         [W-1:0] x,
    output wire                 zero,
    output wire [$clog2(W)-1:0] shamt
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

    // The tree's `valid_stage` at the root would also equal |x, but riding the tree costs WIDX LUT levels
    // (one OR per level). A direct |x synthesises to a balanced LUT4-OR tree at ceil(log4(W)) depth —
    // same logical result, shorter path, and it frees the tree's root OR from a second consumer.
    assign zero  = ~|x;
    assign shamt = shamt_stage[(WIDX * W * WIDX) +: WIDX];
endmodule


`default_nettype wire
