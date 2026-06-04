/// Final ``l = t * P`` multiply for the log2 table+polynomial cores. The Horner output ``acc`` (signed, positive in
/// this regime: ``log2(1+t) > 0`` for ``t in (0,1)``) is multiplied by the stored fraction ``frac`` (unsigned) via the
/// shared _zkf_pmul, and the product is truncated to F2 = WFRAC + CF fractional bits.
/// Zero-bubble; the sideband and valid pipe run along the same register stages as the data.
/// Total register stages are 2+STAGE_PRODUCT (forwarded to _zkf_pmul).

`default_nettype none

module _zkf_log2_final_mul #(
    parameter integer WFRAC         = 17,
    parameter integer WACC          = 35,
    parameter integer F2            = 47,    // = WFRAC + CF
    parameter integer WSB           = 1,
    parameter integer STAGE_PRODUCT = 0,     // forwarded to _zkf_pmul
    parameter integer WMULTIPLIER   = 0      // forwarded to _zkf_pmul
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    in_valid,
    input  wire        [WSB-1:0]   sb_in,
    input  wire        [WFRAC-1:0] frac,
    // acc carries the Horner result P(t) = log2(1+t)/t in [1, 1/ln2] at scale 2**CF; its bits above CF are structural
    // headroom that never toggle. Its meaningful bits are exercised end-to-end by the log2 suite (i_acc below mirrors
    // it one register stage later).
    // verilator coverage_off
    input  wire signed [WACC-1:0]  acc,     // > 0 in this regime
    // verilator coverage_on
    output wire                    out_valid,
    output wire        [WSB-1:0]   sb_out,
    output wire        [F2-1:0]    l_fix
);
    // Input register stage: latch the operands at the module boundary so the multiply has registers on BOTH sides.
    reg  [WFRAC-1:0]       i_frac;
    // verilator coverage_off
    reg  signed [WACC-1:0] i_acc;   // mirrors the acc port (structural top bits); see the acc port comment above
    // verilator coverage_on
    reg                    i_v;
    reg  [WSB-1:0]         i_sb;
    always @(posedge clk) begin
        if (rst) i_v <= 1'b0;
        else     i_v <= in_valid;
        i_frac <= frac;
        i_acc  <= acc;
        i_sb   <= sb_in;
    end

    // Multiply l = t*P = frac*acc, then truncate to F2 fractional bits.
    // acc is non-negative in this regime (log2(1+t) > 0 for t in (0,1)), so it is carried as unsigned; the product is
    // exact in WFRAC+WACC bits and l_fix keeps its low F2 bits.
    // verilator coverage_off
    wire [WFRAC+WACC-1:0] prod_p;
    // verilator coverage_on
    _zkf_pmul #(
        .WA(WFRAC), .WB(WACC), .A_SIGNED(0), .B_SIGNED(0),
        .WSB(WSB), .STAGE_PRODUCT(STAGE_PRODUCT), .WMULTIPLIER(WMULTIPLIER)
    ) u_pmul (
        .clk(clk), .rst(rst), .in_valid(i_v), .sb_in(i_sb),
        .a(i_frac), .b(i_acc),
        .out_valid(out_valid), .sb_out(sb_out), .p(prod_p)
    );
    assign l_fix = prod_p[F2-1:0];
endmodule

`default_nettype wire
