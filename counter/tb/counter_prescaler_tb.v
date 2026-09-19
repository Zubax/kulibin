/// Prescaler testbench for the counter.
/// Run via `fusesoc run --target=sim_prescaler zubax:kulibin:counter`.
///
/// A counter with PRESCALER=P must behave exactly like an unprescaled counter (exhaustively verified by counter_tb)
/// that is enabled only on every (P+1)-th enabled cycle, as selected by an independent model here. With enable held
/// high, at_top must then pulse every (top+1)*(P+1) cycles.

`timescale 1ns/1ns
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module counter_prescaler_tb;
    localparam W = 4;
    localparam PMAX = 3;

    reg clk = 0;
    always #5 clk = !clk;

    reg         rst    = 1;
    reg         enable = 0;
    reg [W-1:0] top    = 0;

    integer period_check = 0;   // nonzero while enable is held high with a constant top from reset
    integer ticks [0:PMAX];

    genvar p;
    generate
        for (p = 0; p <= PMAX; p = p + 1) begin : g_prescaler
            // The reference prescaler: which enabled cycles advance the counter.
            integer phase = 0;
            wire tick = enable && (phase == p);
            always @(posedge clk) begin
                if (rst) begin
                    phase <= 0;
                end else if (enable) begin
                    phase <= tick ? 0 : (phase + 1);
                end
            end

            wire [W-1:0] count;
            wire         at_top;
            wire         at_bot;
            counter#(.W(W), .PRESCALER(p)) dut(
                .clk(clk),
                .rst(rst),
                .enable(enable),
                .top(top),
                .count(count),
                .at_top(at_top),
                .at_bot(at_bot)
            );

            wire [W-1:0] ref_count;
            wire         ref_at_top;
            wire         ref_at_bot;
            counter#(.W(W)) ref_counter(
                .clk(clk),
                .rst(rst),
                .enable(tick),
                .top(top),
                .count(ref_count),
                .at_top(ref_at_top),
                .at_bot(ref_at_bot)
            );

            integer last_at_top = -1;
            integer cycle = 0;
            always @(posedge clk) begin
                #1;
                cycle = cycle + 1;
                `REQUIRE(count === ref_count);
                `REQUIRE(at_top === ref_at_top);
                `REQUIRE(at_bot === ref_at_bot);
                if (tick) ticks[p] = ticks[p] + 1;
                if (period_check == 0) begin
                    last_at_top = -1;
                end else if (at_top) begin
                    if (last_at_top >= 0) `REQUIRE((cycle - last_at_top) == ((top + 1) * (p + 1)));
                    last_at_top = cycle;
                end
            end
        end
    endgenerate

    // Stimulus randomness: a xorshift32 generator.
    reg [31:0] rng = 32'h2545F491;
    function automatic integer rnd;  // uniform in [0, n)
        input integer n;
        begin
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);
            rnd = rng % n;
        end
    endfunction

    integer i;
    integer c;
    initial begin
        for (i = 0; i <= PMAX; i = i + 1) ticks[i] = 0;
        repeat (2) @(negedge clk);

        // Random enable, top changes, and occasional resets.
        for (c = 0; c < 20000; c = c + 1) begin
            rst    = (rnd(500) == 0);
            enable = (rnd(4) != 0);
            if (rnd(50) == 0) top = rnd(1 << W);
            @(negedge clk);
        end

        // Enable held high with a constant top: at_top pulses every (top+1)*(P+1) cycles.
        for (i = 0; i < (1 << W); i = i + 1) begin
            rst = 1;
            enable = 0;
            top = i;
            @(negedge clk);
            rst = 0;
            enable = 1;
            period_check = 1;
            repeat (3 * (i + 1) * (PMAX + 1)) @(negedge clk);
            period_check = 0;
        end

        // Each prescaler must divide the advancing rate by P+1.
        for (i = 1; i <= PMAX; i = i + 1) begin
            `REQUIRE((ticks[i] * (i + 1)) > ((ticks[0] * 9) / 10));
            `REQUIRE((ticks[i] * (i + 1)) < ((ticks[0] * 11) / 10));
        end
        $display("advancing cycles for P = 0..%0d: %0d %0d %0d %0d", PMAX, ticks[0], ticks[1], ticks[2], ticks[3]);
        $finish;
    end
endmodule

`default_nettype wire
