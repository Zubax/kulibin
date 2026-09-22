// iverilog -Wall -Wno-timescale -y. deadtime_complementer_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if(!(cond)) $fatal


module deadtime_complementer_tb;
    localparam integer DEADTIME = 3;  // the dead time of dut_dt3, which the reset checks below measure against

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;  // 100 MHz

    reg in = 0;

    wire pos0, neg0;
    deadtime_complementer #(0) dut_dt0 (.clk(clk), .rst(rst), .in(in), .pos(pos0), .neg(neg0));

    wire pos3, neg3;
    deadtime_complementer #(DEADTIME) dut_dt3 (.clk(clk), .rst(rst), .in(in), .pos(pos3), .neg(neg3));

    // Simple no-shoot-through invariant check at every cycle.
    always @(posedge clk) begin
        if (!rst) begin
            `REQUIRE((pos0 && neg0) === 0);
            `REQUIRE((pos3 && neg3) === 0);
        end
    end

    // A reset arriving while one output is asserted must not let the opposite one assert early on release:
    // otherwise a reset taken with a transistor conducting turns its complement on DEADTIME cycles too soon,
    // which is a shoot-through path straight through the reset. Measures the gap from the asserted output
    // falling to the opposite one rising, across the reset.
    task automatic check_reset_starts_blanked;
        input start_high;   // which output is asserted going into the reset
        input integer rst_cycles;
        integer gap;
        begin
            in = start_high;
            repeat (DEADTIME + 4) @(negedge clk);
            `REQUIRE((start_high ? pos3 : neg3) === 1'b1);  // settled on the starting side

            rst = 1;
            repeat (rst_cycles) @(negedge clk);
            `REQUIRE(pos3 === 1'b0);  // reset blanks both immediately
            `REQUIRE(neg3 === 1'b0);
            in = ~start_high;         // release commanding the opposite side
            rst = 0;

            gap = 0;
            while ((start_high ? neg3 : pos3) !== 1'b1) begin
                `REQUIRE((pos3 && neg3) === 1'b0);
                gap = gap + 1;
                `REQUIRE(gap < 64);   // must eventually assert, or the module is simply dead
                @(negedge clk);
            end
            `REQUIRE(gap >= DEADTIME);
        end
    endtask

    initial begin
        $dumpfile("deadtime_complementer_tb.vcd");
        $dumpvars();

        // Before any clock edge, so this is the declaration initializers rather than the reset path: the outputs
        // must come up low, and the module blanked rather than settled.
        #0;
        `REQUIRE(pos3 === 1'b0);
        `REQUIRE(neg3 === 1'b0);
        `REQUIRE(dut_dt3.active === 1'b1);
        `REQUIRE(pos0 === 1'b0);
        `REQUIRE(neg0 === 1'b0);

        rst = 1;
        repeat (2) @(negedge clk);
        `REQUIRE(pos3 === 1'b0);  // both outputs are low throughout reset
        `REQUIRE(neg3 === 1'b0);
        rst = 0;
        // The first assertion after release waits a full dead time, rather than coming up immediately.
        repeat (DEADTIME - 1) @(negedge clk);
        `REQUIRE(pos3 === 1'b0);
        `REQUIRE(neg3 === 1'b0);
        @(negedge clk);
        `REQUIRE(neg3 === 1'b1);  // in == 0, so the negative side takes it, one full dead time later

        repeat (2) @(negedge clk);

        in = 0;
        repeat (6) @(negedge clk);
        in = 1;
        repeat (6) @(negedge clk);
        in = 0;
        repeat (5) @(negedge clk);
        in = 1;
        repeat (5) @(negedge clk);
        in = 0;
        repeat (4) @(negedge clk);
        in = 1;
        repeat (4) @(negedge clk);
        in = 0;
        repeat (3) @(negedge clk);
        in = 1;
        repeat (3) @(negedge clk);
        in = 0;
        repeat (2) @(negedge clk);
        in = 1;
        repeat (2) @(negedge clk);
        in = 0;
        repeat (1) @(negedge clk);
        in = 1;
        repeat (1) @(negedge clk);

        // Reset taken with either side conducting, and for reset pulses shorter and longer than the dead time.
        check_reset_starts_blanked(1'b1, 1);
        check_reset_starts_blanked(1'b0, 1);
        check_reset_starts_blanked(1'b1, DEADTIME + 2);
        check_reset_starts_blanked(1'b0, DEADTIME + 2);

        $finish;
    end
endmodule
