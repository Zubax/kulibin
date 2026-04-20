// iverilog -Wall -Wno-timescale -y. cast_signed_tb.v && vvp a.out

`timescale 1ns/1ns
`default_nettype none

`define REQUIRE(cond) if(!(cond)) $fatal

/// This bench is pretty lightweight because the core logic is already tested in cast_signed_tb.v
/// and round_signed_tb.v. Here we just verify that the pipelining works correctly.
module cast_signed_tb;

    reg  signed [7:0] din = 0;
    wire signed [3:0] dout;
    wire signed [11:0] dout_widened;
    wire out_valid;

    cast_signed #(.WIN(8), .MSB(2), .LSB(2))   dut         (.din(din), .dout(dout));
    cast_signed #(.WIN(8), .MSB(-2), .LSB(-2)) dut_widening(.din(din), .dout(dout_widened));

    initial begin
        // Test: +max
        din = +127;  // 0111_1111 => 01_1111 => 01_11
        #1;
        `REQUIRE(dout === +7);
        `REQUIRE(dout_widened === +127 * 4);

        // Test: -max
        din = -128;  // 1000_0000 => 10_0000 => 10_00
        #1;
        `REQUIRE(dout === -8);
        `REQUIRE(dout_widened === -128 * 4);

        #1;
        $finish;
    end
endmodule
