/// Simple up-counter with a sampled top value and compare channels.
///
/// The top input is sampled on reset and on the cycle when the counter advances from zero, so a new top takes effect
/// at the start of the next period without disturbing the in-progress cycle.
/// Outputs at_top and at_bot are single-cycle pulses.
///
/// The counter advances only on every (PRESCALER+1)-th enabled cycle, dividing its rate by PRESCALER+1;
/// at_top and at_bot pulse on those cycles only (always one clk long).
///
/// Each of the NCHAN compare channels pulses at_cmp[k] on an advancing cycle where count equals its compare value,
/// cmp[W*k +: W]; like a timer compare register, the value is absolute, not relative to the top. The compare values
/// are sampled together with the top, and the whole period starting at count zero uses the newly sampled values,
/// including its zero count itself. A compare value above the top never matches.
/// Unlike at_cmp, at_top compares against the previous top at count zero, so it does not pulse in a period that
/// starts with a new top of zero.

module counter#(parameter W = 16, parameter PRESCALER = 0, parameter NCHAN = 1)(
    input wire          clk,
    input wire          rst,
    // inputs
    input wire                enable,
    input wire  [W-1:0]       top,
    input wire  [NCHAN*W-1:0] cmp,
    // outputs
    output reg  [W-1:0]       count,
    output wire               at_top,
    output wire               at_bot,
    output wire [NCHAN-1:0]   at_cmp
);
    generate
        if (NCHAN < 1) begin : g_chk_nchan
            counter_error_NCHAN_lt_1 e();
        end
    endgenerate

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
    reg [NCHAN*W-1:0] cmp_r;
    assign at_top = (count == top_r) && tick;
    assign at_bot = (count == 0)     && tick;
    wire [W-1:0] active_top = (count == 0) ? top : top_r;
    wire [NCHAN*W-1:0] active_cmp = (count == 0) ? cmp : cmp_r;

    genvar k;
    generate
        for (k = 0; k < NCHAN; k = k + 1) begin : g_cmp
            assign at_cmp[k] = (count == active_cmp[W*k +: W]) && tick;
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            count <= 0;
            top_r <= top;
            cmp_r <= cmp;
        end else begin
            if (at_bot) begin
                top_r <= top;
                cmp_r <= cmp;
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
