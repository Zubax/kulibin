// iverilog -Wall -Wno-timescale -y. q_cast_p_tb.v && vvp a.out

`default_nettype none
`timescale 1ns / 1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module q_cast_p_tb;
    reg clk = 0;
    always #1 clk = ~clk;
    reg rst = 0;

    reg              in_valid = 0;
    reg signed [7:0] in_data = 0;

    wire              out_narrow_valid;
    wire signed [3:0] out_narrow;
    q_cast_p#(.QIN(3005), .QOUT(2002)) cast_narrow(
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in(in_data),
        .out_valid(out_narrow_valid),
        .out(out_narrow)
    );

    wire              out_round_valid;
    wire signed [4:0] out_round;
    q_cast_p#(.QIN(3005), .QOUT(3002)) cast_round(
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in(in_data),
        .out_valid(out_round_valid),
        .out(out_round)
    );

    wire               out_wide_valid;
    wire signed [11:0] out_wide;
    q_cast_p#(.QIN(3005), .QOUT(6006)) cast_wide(
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in(in_data),
        .out_valid(out_wide_valid),
        .out(out_wide)
    );

    initial begin
        $dumpfile("q_cast_p_tb.vcd");
        $dumpvars();
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // Test
        in_data  = 8'b001_11000;  // 1.75
        in_valid = 1;
        @(negedge clk);
        in_valid = 0;
        `REQUIRE(out_wide_valid);
        `REQUIRE(out_wide === 12'b000001_110000);
        `REQUIRE(out_round_valid);
        `REQUIRE(out_round === 5'b001_11);
        `REQUIRE(!out_narrow_valid);
        @(negedge clk);
        `REQUIRE(!out_wide_valid);
        `REQUIRE(!out_round_valid);
        `REQUIRE(out_narrow_valid);
        `REQUIRE(out_narrow === 4'b01_11);
        @(negedge clk);
        `REQUIRE(!out_wide_valid);
        `REQUIRE(!out_round_valid);
        `REQUIRE(!out_narrow_valid);

        $finish;
    end
endmodule
