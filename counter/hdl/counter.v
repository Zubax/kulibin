/// Simple up-counter with a sampled top value.
///
/// The top input is sampled on reset and whenever the counter is at zero. This allows updating the next period length
/// without changing the current in-progress cycle.

module counter#(parameter W = 16)(
    input wire          clk,
    input wire          rst,
    // inputs
    input wire          enable,
    input wire  [W-1:0] top,
    // outputs
    output reg  [W-1:0] count,
    output wire         at_top,
    output wire         at_bot
);
    reg [W-1:0] top_r;
    assign at_top = count == top_r;
    assign at_bot = count == 0;
    wire [W-1:0] active_top = at_bot ? top : top_r;

    always @(posedge clk) begin
        if (rst) begin
            count <= 0;
            top_r <= top;
        end else begin
            if (at_bot) begin
                top_r <= top;
            end
            if (enable) begin
                if (count == active_top) begin
                    count <= 0;
                end else begin
                    count <= count + 1;
                end
            end
        end
    end
endmodule
