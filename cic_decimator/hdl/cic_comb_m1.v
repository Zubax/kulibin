/// A generic comb filter with a fixed delay of M=1 sample.
/// The comb filter function is y(t) = x(t) - x(t-M).
/// The state is updated when enable is asserted, otherwise the same output is held.

module cic_comb_m1#(parameter W = 8)(
    input wire clk,
    input wire rst,
    input wire enable,
    input wire signed [W-1:0] x,
    output reg signed [W-1:0] y
);
    reg signed [W-1:0] z;
    always @(posedge clk) begin
        if (rst) begin
            z <= 0;
            y <= 0;
        end else if (enable) begin
            y <= x - z;
            z <= x;
        end
    end
endmodule
