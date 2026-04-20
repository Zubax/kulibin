// iverilog -Wall -Wno-timescale -y. cast_signed_p_tb.v && vvp a.out

`timescale 1ns/1ns
`default_nettype none

`define REQUIRE(cond) if(!(cond)) $fatal

/// This bench is pretty lightweight because the core logic is already tested in cast_signed_tb.v
/// and round_signed_tb.v. Here we just verify that the pipelining works correctly.
module cast_signed_p_tb;

    reg rst = 0;
    reg clk = 0;
    reg in_valid = 0;
    reg  signed [7:0] din = 0;
    wire signed [3:0] dout;
    wire signed [11:0] dout_widened;
    wire out_valid;
    wire out_valid_widened;

    cast_signed_p #(.WIN(8), .MSB(2), .LSB(2)) dut(
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_data(din),
        .out_valid(out_valid),
        .out_data(dout)
    );
    cast_signed_p #(.WIN(8), .MSB(-2), .LSB(-2)) dut_widening(
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_data(din),
        .out_valid(out_valid_widened),
        .out_data(dout_widened)
    );

    always #5 clk = !clk;

    initial begin
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);
        `REQUIRE(out_valid === 0);

        // Test: +max
        din = +127;  // 0111_1111 => 01_1111 => 01_11
        in_valid = 1;
        `REQUIRE(out_valid === 0);
        @(negedge clk);
        in_valid = 0;
        @(negedge clk);
        `REQUIRE(out_valid === 1);
        `REQUIRE(dout === +7);
        `REQUIRE(dout_widened === +127 * 4);
        @(negedge clk);
        `REQUIRE(out_valid === 0);

        // Test: -max
        din = -128;  // 1000_0000 => 10_0000 => 10_00
        in_valid = 1;
        `REQUIRE(out_valid === 0);
        @(negedge clk);
        in_valid = 0;
        @(negedge clk);
        `REQUIRE(out_valid === 1);
        `REQUIRE(dout === -8);
        `REQUIRE(dout_widened === -128 * 4);
        @(negedge clk);
        `REQUIRE(out_valid === 0);

        @(negedge clk);
        $finish;
    end

    initial begin
        $dumpfile("cast_signed_p_tb.vcd");
        $dumpvars();
    end
endmodule
