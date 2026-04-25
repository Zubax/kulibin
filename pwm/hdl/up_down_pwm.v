/// Basic pulse-width modulator with a bidirectional counter.
/// The modulation frequency equals clk / (top * 2).
/// Inputs top and compare are sampled according to SHADOW_RELOAD: 1 = top, 2 = bottom, 3 = both (default).
/// The at_top and at_bot outputs indicate counter extrema independently of SHADOW_RELOAD.

module up_down_pwm#(
    parameter W             = 16,
    parameter SHADOW_RELOAD = 3
)(
    input wire         clk,
    input wire         rst,
    input wire [W-1:0] top,
    input wire [W-1:0] compare,
    output wire        at_top,
    output wire        at_bot,
    output reg         out
);
    reg [W-1:0] counter;
    reg         reverse;
    reg [W-1:0] top_r;
    reg [W-1:0] compare_r;

    localparam SHADOW_RELOAD_TOP = 1;
    localparam SHADOW_RELOAD_BOT = 2;

    initial if ((SHADOW_RELOAD < 1) || (SHADOW_RELOAD > 3)) $fatal;

    assign at_top = (counter == top_r) && !reverse;
    assign at_bot = (counter == 0)     &&  reverse;

    wire reload_at_top = (SHADOW_RELOAD & SHADOW_RELOAD_TOP) != 0;
    wire reload_at_bot = (SHADOW_RELOAD & SHADOW_RELOAD_BOT) != 0;
    wire shadow_reload = (reload_at_top && at_top) || (reload_at_bot && at_bot) || ((top_r == 0) && !reload_at_top);

    always @(posedge clk) begin
        if (rst) begin
            counter     <= 0;
            reverse     <= 0;
            top_r       <= 0;
            compare_r   <= 0;
            out         <= 0;
        end else begin
            // Counting logic.
            if (top_r == 0) begin
                reverse <= 0;
                counter <= 0;
            end else if (at_top) begin
                reverse <= 1;
                counter <= counter - 1;
            end else if (at_bot) begin
                reverse <= 0;
                counter <= counter + 1;
            end else begin
                counter <= reverse ? counter - 1 : counter + 1;
            end

            // Shadow register latching logic.
            if (shadow_reload) begin
                top_r       <= top;
                compare_r   <= compare;
            end

            // Output trigger logic.
            if (compare_r == 0) begin
                out <= 0;
            end else if (compare_r == top_r) begin
                out <= 1;
            end else if (counter == compare_r) begin
                out <= reverse;
            end
        end
    end
endmodule
