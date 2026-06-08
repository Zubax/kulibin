/// Final ``log2(m') = f * C(f)`` multiply for the log2 table+polynomial cores. The Horner output ``acc`` (signed, but
/// non-negative in this regime: ``C(f) = log2(1+f)/f > 0`` over the whole reduced range) is multiplied by the SIGNED
/// reduced argument ``f`` (= F at scale 2**-(WFRAC+1); ``f < 0`` when ``m >= sqrt(2)``) via the shared _zkf_pmul, and
/// the full signed product is sign-clipped to the F2 = WFRAC+1+CF fractional scale of the accumulator in zkf_log2.
/// The caller passes acc trimmed to its meaningful width (WACC ~ CF+2): C(f) < 2 so the Horner accumulator's high
/// guard bits are structurally zero, and dropping them keeps every multiplier slice inside one DSP tile.
/// Zero-bubble; the sideband and valid pipe run along the same register stages as the data.
/// Total register stages are 2+STAGE_PRODUCT (forwarded to _zkf_pmul).

`default_nettype none

module _zkf_log2_final_mul #(
    parameter integer WF            = 18,    // signed reduced-argument width (= WFRAC + 1)
    parameter integer WACC          = 35,
    parameter integer F2            = 48,    // = WFRAC + 1 + CF
    parameter integer WSB           = 1,
    parameter integer STAGE_PRODUCT = 0,     // forwarded to _zkf_pmul
    parameter integer WMULTIPLIER   = 0      // forwarded to _zkf_pmul
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    in_valid,
    input  wire        [WSB-1:0]   sb_in,
    input  wire signed [WF-1:0]    f,       // signed reduced argument F (scale 2**-(WFRAC+1))
    // acc carries the Horner result C(f) = log2(1+f)/f in [~1.21, ~1.71] at scale 2**CF; it is non-negative over the
    // whole reduced range (C(f) > 0), so it is carried as unsigned (B_SIGNED=0). The caller trims it to its meaningful
    // width (the high guard bits are structurally zero). Its meaningful bits are exercised end-to-end by the log2 suite
    // (i_acc below mirrors it one register stage later).
    // verilator coverage_off
    input  wire        [WACC-1:0]  acc,     // >= 0 in this regime, trimmed to its meaningful width by the caller
    // verilator coverage_on
    output wire                    out_valid,
    output wire        [WSB-1:0]   sb_out,
    output wire signed [F2:0]      l_fix    // SIGNED f*C(f) = log2(m') at scale 2**-F2 (F2+1 bits)
);
    // Input register stage: latch the operands at the module boundary so the multiply has registers on BOTH sides.
    reg  signed [WF-1:0]   i_f;
    // verilator coverage_off
    reg         [WACC-1:0] i_acc;   // mirrors the acc port; see the acc port comment above
    // verilator coverage_on
    reg                    i_v;
    reg  [WSB-1:0]         i_sb;
    always @(posedge clk) begin
        if (rst) i_v <= 1'b0;
        else     i_v <= in_valid;
        i_f    <= f;
        i_acc  <= acc;
        i_sb   <= sb_in;
    end

    // Signed multiply l = f * C(f) = f * acc. f is signed; acc is non-negative (C(f) > 0 over the reduced range) so it
    // is carried unsigned (B_SIGNED=0). The shared _zkf_pmul returns the exact WF+WACC-bit two's-complement product.
    // verilator coverage_off
    wire [WF+WACC-1:0] prod_p;
    // verilator coverage_on
    _zkf_pmul #(
        .WA(WF), .WB(WACC), .A_SIGNED(1), .B_SIGNED(0),
        .WSB(WSB), .STAGE_PRODUCT(STAGE_PRODUCT), .WMULTIPLIER(WMULTIPLIER)
    ) u_pmul (
        .clk(clk), .rst(rst), .in_valid(i_v), .sb_in(i_sb),
        .a(i_f), .b(i_acc),
        .out_valid(out_valid), .sb_out(sb_out), .p(prod_p)
    );
    // The product magnitude |f*C(f)| < 2**F2 over the whole reduced range, so it fits in F2+1 signed bits exactly; the
    // bits above F2 are pure sign extension. Keep the low F2+1 bits as the signed log2(m') the combine in zkf_log2 adds
    // to e<<F2. (WF+WACC > F2+1 by construction, since WACC = CF + a couple of headroom bits.)
    assign l_fix = $signed(prod_p[F2:0]);
endmodule

`default_nettype wire
