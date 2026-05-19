/// Streamed cast from signed two's-complement integer to Zubax Kulibin float.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Register stages: 4+STAGE_INPUT end-to-end.

`default_nettype none

module zkf_from_int #(
    parameter WEXP        = 6,
    parameter WMAN        = 18,
    parameter WINT        = 32,
    parameter STAGE_INPUT = 0   // whether to add a stage at the input (shields inputs from combinational paths)
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

    // Optional input register stage.
    wire             in_valid_q;
    wire [WINT-1:0]  a_q;
    _zkf_pipe #(.W(WINT), .N(STAGE_INPUT ? 1 : 0)) u_input_pipe (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in(a), .out_valid(in_valid_q), .out(a_q)
    );

    // Stage-1 cone: form |a| via XOR-and-increment so the carry chain handles the negation; this also handles
    // INT_MIN correctly because the resulting unsigned magnitude 2^(WINT-1) fits in WINT bits.
    wire            sign_in    = a_q[WINT-1];
    wire [WINT-1:0] inv_in     = a_q ^ {WINT{sign_in}};
    wire [WINT-1:0] mag_in     = inv_in + {{(WINT-1){1'b0}}, sign_in};
    wire [WX-1:0]   mag_ext_in = {{(WX-WINT){1'b0}}, mag_in};

    // Stage 1: register sign and magnitude. Reset only validity; payload free-runs.
    reg            s1_valid;
    reg            s1_sign;
    reg [WX-1:0]   s1_mag_ext;

    // Stage-2 cone: LOD on the registered magnitude. The output shamt is the left-shift count that brings the
    // leading 1 to bit (WX-1); zero is the OR-reduction of the magnitude, which _zkf_pack will use as force_zero.
    wire            s1_zero;
    wire [WIDX-1:0] s1_shamt;
    _zkf_lod #(.W(WX)) u_lod (.x(s1_mag_ext), .zero(s1_zero), .shamt(s1_shamt));

    // Stage 2: register the LOD outputs and the magnitude. Reset only validity; payload free-runs.
    reg            s2_valid;
    reg            s2_sign;
    reg [WX-1:0]   s2_mag_ext;
    reg            s2_zero;
    reg [WIDX-1:0] s2_shamt;

    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
        end else begin
            s1_valid <= in_valid_q;
            s2_valid <= s1_valid;
        end
        s1_sign    <= sign_in;
        s1_mag_ext <= mag_ext_in;

        s2_sign    <= s1_sign;
        s2_mag_ext <= s1_mag_ext;
        s2_zero    <= s1_zero;
        s2_shamt   <= s1_shamt;
    end

    // Stage 2 -> _zkf_pack inputs combinational: barrel shift (LOD already done) plus GRS extraction and exponent
    // derivation. Significand carries the hidden leading 1 at the top; the next two bits feed guard/round, and any
    // remaining bits below OR-reduce into sticky.
    wire   [WX-1:0] s2_aligned     =  s2_mag_ext << s2_shamt;
    wire [WMAN-1:0] s2_significand =  s2_aligned[WX-1 -: WMAN];
    wire            s2_guard       =  s2_aligned[WX-WMAN-1];
    wire            s2_round       =  s2_aligned[WX-WMAN-2];
    wire            s2_sticky      = |s2_aligned[WX-WMAN-3:0];

    // exp_unbiased = position of the leading 1 = (WX-1) - shamt. The subtraction sits on the carry chain and is the
    // same shape as the bias subtraction inside _zkf_pack, avoiding a separate comparator.
    //
    // Invariant: shamt is in [0, WX-1] for every input, including all-zero.
    // The LOD's leaves store LEAF_SHIFT = WX-1-i in [0, WX-1] and the tree only propagates leaf values (no arithmetic),
    // so the root shamt is always a leaf value. The subtraction below therefore never underflows; zero-extending into
    // s2_exp_ub is safe and does not need sign extension. For all-zero magnitude in particular, shamt = WX-1 produces
    // s2_exp_ub = 0, but _zkf_pack ignores exp_unbiased when force_zero (= s2_zero) is asserted.
    wire        [WIDX:0]  s2_top_ext   = WX - 1;
    wire        [WIDX:0]  s2_shamt_ext = {1'b0, s2_shamt};
    wire        [WIDX:0]  s2_pos_ext   = s2_top_ext - s2_shamt_ext;
    wire signed [WEU-1:0] s2_exp_ub    = {{(WEU-WIDX-1){1'b0}}, s2_pos_ext};

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEU)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s2_valid),
        .sign(s2_sign),
        .force_zero(s2_zero),
        .force_inf(1'b0),
        .exp_unbiased(s2_exp_ub),
        .significand(s2_significand),
        .guard(s2_guard),
        .round(s2_round),
        .sticky(s2_sticky),
        .out_valid(out_valid),
        .y(y)
    );
endmodule


`default_nettype wire
