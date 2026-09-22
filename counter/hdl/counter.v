/// Simple up-counter with a sampled top value and compare channels.
///
/// The top input is sampled on the cycle when the counter advances from zero, so a new top takes effect at the
/// start of the next period without disturbing the in-progress cycle.
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
///
/// All three strobe outputs mark a running counter only: they stay low throughout reset, where the count is held
/// at zero and therefore is not advancing. Without that qualification a consumer that leaves enable asserted over
/// a reset would see at_bot, and any compare channel set to zero, pulse on every cycle of it. The internal
/// sampling still uses the unqualified extrema, which is immaterial there because it is already in the
/// non-reset branch, but keeps the counter's own behavior independent of how the ports are presented.
/// Being combinational, the strobes are meant to be sampled on clk rather than used as a clock or an edge
/// trigger; they follow enable directly, so they carry whatever glitches it has.

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
    wire at_top_raw = (count == top_r) && tick;
    wire at_bot_raw = (count == 0)     && tick;
    assign at_top = at_top_raw && !rst;
    assign at_bot = at_bot_raw && !rst;
    wire [W-1:0] active_top = (count == 0) ? top : top_r;
    wire [NCHAN*W-1:0] active_cmp = (count == 0) ? cmp : cmp_r;

    genvar k;
    generate
        for (k = 0; k < NCHAN; k = k + 1) begin : g_cmp
            assign at_cmp[k] = (count == active_cmp[W*k +: W]) && tick && !rst;
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            count <= 0;
            // All ones rather than the inputs. The live inputs are used at count zero anyway,
            // so this costs nothing beyond at_top staying low until the first sample.
            top_r <= {W{1'b1}};
            cmp_r <= {NCHAN*W{1'b1}};
        end else begin
            if (at_bot_raw) begin
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
