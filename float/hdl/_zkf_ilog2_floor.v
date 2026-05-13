/// A combinational circuit finding floor(log2(x)).
/// If the input is zero, the zero flag is asserted and y=0.

module _zkf_ilog2_floor #(
    parameter W      = 16,
    parameter WINDEX = (W <= 2) ? 1 : $clog2(W)
) (
    input  wire [W-1:0]      x,
    output wire              zero,
    output wire [WINDEX-1:0] y
);
    generate
        if (W == 1) begin : g_base
            assign zero = ~x[0];
            assign y    = {WINDEX{1'b0}};
        end else begin : g_recurse
            localparam WHI = W / 2;
            localparam WLO = W - WHI;

            wire zero_lo;
            wire zero_hi;

            wire [WINDEX-1:0] index_lo;
            wire [WINDEX-1:0] index_hi;

            _zkf_ilog2_floor #(.W(WLO), .WINDEX(WINDEX)) u_lo (.x(x[WLO-1:0]), .zero(zero_lo), .y(index_lo));
            _zkf_ilog2_floor #(.W(WHI), .WINDEX(WINDEX)) u_hi (.x(x[W-1:WLO]), .zero(zero_hi), .y(index_hi));

            assign zero = zero_lo & zero_hi;
            assign y    = zero_hi ? index_lo : index_hi + WLO[WINDEX-1:0];
        end
    endgenerate
endmodule
