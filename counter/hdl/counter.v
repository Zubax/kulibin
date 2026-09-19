/// Simple up-counter with a sampled top value.
///
/// The top input is sampled on reset and on the cycle when the counter advances from zero, so a new top takes effect
/// at the start of the next period without disturbing the in-progress cycle.
/// Outputs at_top and at_bot are single-cycle pulses.
///
/// The counter advances only on every (PRESCALER+1)-th enabled cycle, dividing its rate by PRESCALER+1;
/// at_top and at_bot pulse on those cycles only (always one clk long).

module counter#(parameter W = 16, parameter PRESCALER = 0)(
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
    // The counter advances on the cycles when tick is high.
    wire tick;
    generate
        if (PRESCALER > 0) begin : g_prescaler
            /* verilator lint_off WIDTHTRUNC */
            localparam [$clog2(PRESCALER+1)-1:0] PRESCALER_LAST = PRESCALER;
            /* verilator lint_on WIDTHTRUNC */
            reg [$clog2(PRESCALER+1)-1:0] prescaler;
            assign tick = enable && (prescaler == PRESCALER_LAST);
            always @(posedge clk) begin
                if (rst) begin
                    prescaler <= 0;
                end else if (enable) begin
                    prescaler <= tick ? 0 : (prescaler + 1'b1);
                end
            end
        end else begin : g_no_prescaler
            assign tick = enable;
        end
    endgenerate

    reg [W-1:0] top_r;
    assign at_top = (count == top_r) && tick;
    assign at_bot = (count == 0)     && tick;
    wire [W-1:0] active_top = (count == 0) ? top : top_r;

    always @(posedge clk) begin
        if (rst) begin
            count <= 0;
            top_r <= top;
        end else begin
            if (at_bot) begin
                top_r <= top;
            end
            if (tick) begin
                if (count == active_top) begin
                    count <= 0;
                end else begin
                    count <= count + 1'b1;
                end
            end
        end
    end
endmodule
