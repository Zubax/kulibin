// iverilog -Wall -Wno-timescale -y. round_signed_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if(!(cond)) $fatal

module round_signed_tb;

    reg  signed [7:0] din = 0;
    wire signed [3:0] dout_narrow;
    wire signed [9:0] dout_wide;

    round_signed #(.WIN(8), .WOUT(4)) dut_narrowing(.din(din), .dout(dout_narrow));
    round_signed #(.WIN(8), .WOUT(10)) dut_widening(.din(din), .dout(dout_wide));

    initial begin
        // Test: +max, rounding suppressed to avoid overflow
        din = +127;
        #1;
        `REQUIRE(dout_narrow === +7);
        `REQUIRE(dout_wide   === +127 * 4);

        // Test: +max-1, rounding suppressed to avoid overflow
        din = +126;
        #1;
        `REQUIRE(dout_narrow === +7);
        `REQUIRE(dout_wide   === +126 * 4);

        // Test: tie rounds to even
        din = +104;
        #1;
        `REQUIRE(dout_narrow === +6);
        `REQUIRE(dout_wide   === +104 * 4);

        // Test: round up, no risk of overflow
        din = +105;
        #1;
        `REQUIRE(dout_narrow === +7);
        `REQUIRE(dout_wide   === +105 * 4);

        // Test: -max
        din = -128;
        #1;
        `REQUIRE(dout_narrow === -8);
        `REQUIRE(dout_wide   === -128 * 4);

        // Test: -1 rounds to zero
        din = -1;
        #1;
        `REQUIRE(dout_narrow === +0);
        `REQUIRE(dout_wide   === -1 * 4);

        // Test: positive definitive round toward zero
        din = +68;                     // 0100'0100, the remainder rounds toward zero
        #1;
        `REQUIRE(dout_narrow === +4);  // 0100
        `REQUIRE(dout_wide   === +68 * 4);

        // Test: negative definitive round toward zero
        din = -68;                    // 1011'1100, the remainder rounds toward zero
        #1;
        `REQUIRE(dout_narrow === -4);  // 1100
        `REQUIRE(dout_wide   === -68 * 4);

        // Test: positive definitive round away from zero
        din = +73;                    // 0100'1001, the remainder rounds away from zero due to the LSB 1
        #1;
        `REQUIRE(dout_narrow === +5);  // 0101
        `REQUIRE(dout_wide   === +73 * 4);

        // Test: negative definitive round away from zero
        din = -73;                    // 1011'0111, the remainder rounds away from zero
        #1;
        `REQUIRE(dout_narrow === -5);  // 1010
        `REQUIRE(dout_wide   === -73 * 4);

        // Test: positive tie rounds to even
        din = +72;                    // 0100'1000, the remainder is exactly half
        #1;
        `REQUIRE(dout_narrow === +4);  // 0100
        `REQUIRE(dout_wide   === +72 * 4);

        // Test: negative tie rounds to even
        din = -72;                    // 1011'1000, the remainder is exactly half
        #1;
        `REQUIRE(dout_narrow === -4);  // 1100
        `REQUIRE(dout_wide   === -72 * 4);

        $finish;
    end
endmodule
