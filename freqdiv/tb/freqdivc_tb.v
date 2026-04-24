/// iverilog -Wall -Wno-timescale -y. freqdivc_tb.v && vvp a.out

`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module freqdivc_tb;
    reg clk = 0;
    always #5 clk = !clk;

    reg rst = 0;

    wire out1;
    wire out2;
    wire out3;
    wire out3p;
    wire out4;
    wire out5;
    wire out5p;
    wire out6;
    wire out7;
    wire out8;
    wire out9;
    wire out10;

    reg enable = 0;

    // verilog_lint: waive-start module-port
    // verilog_lint: waive-start module-parameter
    freqdivc#(2)  fd2 (clk, rst, enable, out2);
    freqdivc#(1)  fd1 (clk, rst, enable, out1);
    freqdivc#(3)  fd3 (clk, rst, enable, out3);
    freqdivc#(3,1)fd3p(clk, rst, enable, out3p);
    freqdivc#(4)  fd4 (clk, rst, enable, out4);
    freqdivc#(5)  fd5 (clk, rst, enable, out5);
    freqdivc#(5,1)fd5p(clk, rst, enable, out5p);
    freqdivc#(6)  fd6 (clk, rst, enable, out6);
    freqdivc#(7)  fd7 (clk, rst, enable, out7);
    freqdivc#(8)  fd8 (clk, rst, enable, out8);
    freqdivc#(9)  fd9 (clk, rst, enable, out9);
    freqdivc#(10) fd10(clk, rst, enable, out10);
    // verilog_lint: waive-stop module-parameter
    // verilog_lint: waive-stop module-port

    initial begin
        enable = 1;
        rst = 1;

        @(posedge clk);
        #1 `REQUIRE(out1 === 1'b0);  // Reset holds the N=1 gated output low even with clk and enable high.

        @(negedge clk);
        enable = 0;
        @(negedge clk);
        rst = 0;

        @(posedge clk);
        #1 `REQUIRE(out1 === 1'b0);
        enable = 1;                  // Enable while clk is already high.
        #1 `REQUIRE(out1 === 1'b0);  // This must not create an immediate output edge.
        @(negedge clk);
        #1 `REQUIRE(out1 === 1'b0);
        @(posedge clk);
        #1 `REQUIRE(out1 === 1'b1);  // The first enabled output high begins on an input clock posedge.

        @(negedge clk);
        #300
        enable = 0;
        #50
        enable = 1;
        #50
        $finish;
    end

    initial begin
        $dumpfile("freqdivc_tb.vcd");
        $dumpvars();
    end
endmodule
