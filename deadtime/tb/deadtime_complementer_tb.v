// iverilog -Wall -Wno-timescale -y. deadtime_complementer_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if(!(cond)) $fatal


module deadtime_complementer_tb;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;  // 100 MHz

    reg in = 0;

    wire pos0, neg0;
    deadtime_complementer #(0) dut_dt0 (.clk(clk), .rst(rst), .in(in), .pos(pos0), .neg(neg0));

    wire pos3, neg3;
    deadtime_complementer #(3) dut_dt3 (.clk(clk), .rst(rst), .in(in), .pos(pos3), .neg(neg3));

    // Simple no-shoot-through invariant check at every cycle.
    always @(posedge clk) begin
        if (!rst) begin
            `REQUIRE((pos0 && neg0) === 0);
            `REQUIRE((pos3 && neg3) === 0);
        end
    end

    initial begin
        $dumpfile("deadtime_complementer_tb.vcd");
        $dumpvars();

        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
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

        $finish;
    end
endmodule
