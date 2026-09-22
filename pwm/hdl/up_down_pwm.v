/// Basic pulse-width modulator with a bidirectional counter.
/// The modulation frequency equals clk / (top * 2).
/// Inputs top and compare are sampled according to SHADOW_RELOAD: 1 = top, 2 = bottom, 3 = both (default).
/// The at_top and at_bot outputs indicate counter extrema independently of SHADOW_RELOAD.
///
/// The NCHAN compare channels share one counter, hence one carrier period and phase; only the duty cycle is
/// per-channel. Channel k is driven by compare[W*k +: W] and drives out[k]; the channels are otherwise independent.
/// Being shared, top, at_top, and at_bot are common to all channels, and so is the shadow reload instant: the whole
/// compare bus is latched together with top, so a coherent update of all channels requires no extra synchronization.
/// A compare of zero holds its output low and a compare equal to the top holds it high, zero taking precedence when
/// the top is zero too; a compare above the top never matches, so that channel freezes at the level it last held.

module up_down_pwm#(
    parameter W             = 16,
    parameter SHADOW_RELOAD = 3,
    parameter NCHAN         = 1
)(
    input wire               clk,
    input wire               rst,
    input wire [W-1:0]       top,
    input wire [NCHAN*W-1:0] compare,
    output wire              at_top,
    output wire              at_bot,
    output reg [NCHAN-1:0]   out
);
    reg [W-1:0]       counter;
    reg               reverse;
    reg [W-1:0]       top_r;
    reg [NCHAN*W-1:0] compare_r;
    integer           i;

    localparam SHADOW_RELOAD_TOP = 1;
    localparam SHADOW_RELOAD_BOT = 2;

    initial if ((SHADOW_RELOAD < 1) || (SHADOW_RELOAD > 3)) $fatal;

    generate
        if (NCHAN < 1) begin : g_chk_nchan
            up_down_pwm_error_NCHAN_lt_1 e();
        end
    endgenerate

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

            // Output trigger logic, per channel.
            for (i = 0; i < NCHAN; i = i + 1) begin
                if (compare_r[W*i +: W] == 0) begin
                    out[i] <= 0;
                end else if (compare_r[W*i +: W] == top_r) begin
                    out[i] <= 1;
                end else if (counter == compare_r[W*i +: W]) begin
                    out[i] <= reverse;
                end
            end
        end
    end
endmodule
