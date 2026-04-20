/// iverilog -Wall -Wno-timescale -y. cic_comb_m1_tb.v && vvp a.out

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_comb_m1_tb;
    reg clk = 0;
    always #5 clk = !clk;

    reg rst = 0;
    reg enable = 0;
    reg signed [2:0] x = 0;
    wire signed [2:0] y;

    cic_comb_m1 #(3) dut (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .x(x),
        .y(y)
    );

    initial begin
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        x = 3'b010;
        @(negedge clk);  // no effect while enable is low
        `REQUIRE(y == 0);
        enable = 1;
        @(negedge clk);
        enable = 0;
        @(negedge clk);
        `REQUIRE(y == 3'b010);

        x = 3'b001;
        enable = 1;
        @(negedge clk);
        enable = 0;
        `REQUIRE(y == 3'b111);  // -1 signed

        $finish;
    end

    initial begin
        $dumpfile("cic_comb_m1_tb.vcd");
        $dumpvars();
    end
endmodule
