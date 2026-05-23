/// Streamed cast from signed two's-complement integer to Zubax Kulibin float.
/// Register stages: 2+STAGE_INPUT+STAGE_OUTPUT end-to-end.
///
/// STAGE_INPUT=0: input combinational paths are exposed.
/// STAGE_INPUT=1: inputs are latched, the external module sees registers at the input (one extra cycle).
///
/// STAGE_OUTPUT=0: outputs are combinational (default)
/// STAGE_OUTPUT=1: registered (one extra cycle).

`default_nettype none

module zkf_from_int #(
    parameter WEXP         = 6,
    parameter WMAN         = 18,
    parameter WINT         = 32,
    parameter STAGE_INPUT  = 0,
    parameter STAGE_OUTPUT = 0
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
    // verilator coverage_off
    // Magnitude formation: the WX-wide carrier zero-extends the WINT magnitude (WX>WINT padding is
    // constant), and at wide WINT the random stimulus does not toggle every high bit both ways. The
    // magnitude flows into the LOD and the significand/GRS extraction below, which stay covered.
    wire [WINT-1:0] inv_in     = a_q ^ {WINT{sign_in}};
    wire [WINT-1:0] mag_in     = inv_in + {{(WINT-1){1'b0}}, sign_in};
    wire [WX-1:0]   mag_ext_in = {{(WX-WINT){1'b0}}, mag_in};
    // verilator coverage_on

    // Stage 1: register sign and magnitude. Reset only validity; payload free-runs.
    reg            s1_valid;
    reg            s1_sign;
    // WX-wide magnitude reg; the WX>WINT high bits are constant zero-padding.
    // verilator coverage_off
    reg [WX-1:0]   s1_mag_ext;
    // verilator coverage_on

    // Fused leading-zero normalize + left shift on the registered magnitude. STAGE_SPLIT=1 places one register
    // inside the cascade, so zero/shamt/aligned all arrive one cycle later (stage 2), matching the s2_sign/s2_valid
    // pipeline. shamt is the left-shift count that brings the leading 1 to bit (WX-1); zero is the magnitude
    // OR-reduction, which _zkf_pack uses as force_zero. This replaces the former _zkf_lod plus a separate barrel shift.
    wire            s2_zero;
    wire [WIDX-1:0] s2_shamt;
    // left-justified magnitude; its slices feed the covered significand/GRS below.
    // verilator coverage_off
    wire   [WX-1:0] s2_aligned;
    // verilator coverage_on
    _zkf_normshift #(.W(WX), .STAGE_SPLIT(1)) u_norm (
        .clk(clk),
        .x(s1_mag_ext),
        .zero(s2_zero),
        .count(s2_shamt),
        .y(s2_aligned)
    );

    // Stage 2: register sign alongside the normalize pipeline. Reset only validity; payload free-runs.
    reg            s2_valid;
    reg            s2_sign;

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
    end

    // Stage 2 -> _zkf_pack inputs combinational: GRS extraction and exponent derivation from the normalized
    // magnitude. Significand carries the hidden leading 1 at the top; the next two bits feed guard/round, and any
    // remaining bits below OR-reduce into sticky.
    wire [WMAN-1:0] s2_significand =  s2_aligned[WX-1 -: WMAN];
    wire            s2_guard       =  s2_aligned[WX-WMAN-1];
    wire            s2_round       =  s2_aligned[WX-WMAN-2];
    wire            s2_sticky      = |s2_aligned[WX-WMAN-3:0];

    // Biased exponent = leading-one position + BIAS = ((WX-1) - shamt) + BIAS = (WX-1 + BIAS) - shamt, formed as a
    // single subtraction so _zkf_pack can skip its own bias add (EXP_IS_BIASED). Folding the bias in here keeps the
    // pre-pack cone short enough for the single-stage packer; the value is always >= BIAS (positive). For all-zero
    // input the result is don't-care because force_zero (= s2_zero) overrides it.
    //
    // shamt is the radix-4 normalize count; for nonzero input it is in [0, WX-1], so s2_exp_biased is in
    // [BIAS, WX-1+BIAS] and never underflows. WEU >= WEXP+2 holds (WX-1+BIAS) and gives _zkf_pack the headroom its
    // overflow detection needs.
    localparam [WEU-1:0] EXP_BIASED_TOP = (WX - 1) + ((1 << (WEXP - 1)) - 1);
    // verilator coverage_off
    // s2_shamt zero-extended to WEU; the pad bits and (for valid inputs) the top of s2_exp_biased are constant.
    wire        [WEU-1:0] s2_shamt_ext  = {{(WEU-WIDX){1'b0}}, s2_shamt};
    wire signed [WEU-1:0] s2_exp_biased = EXP_BIASED_TOP - s2_shamt_ext;
    // verilator coverage_on

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEU), .EXP_IS_BIASED(1), .STAGE_OUTPUT(STAGE_OUTPUT)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(s2_valid),
        .sign(s2_sign),
        .force_zero(s2_zero),
        .force_inf(1'b0),
        .exp_unbiased(s2_exp_biased),
        .significand(s2_significand),
        .guard(s2_guard),
        .round(s2_round),
        .sticky(s2_sticky),
        .out_valid(out_valid),
        .y(y)
    );
endmodule


`default_nettype wire
