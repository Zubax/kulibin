// iverilog -Wall -Wno-timescale -y. fir_tb.v && vvp a.out

`default_nettype none
`timescale 1ns / 1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module fir_tb;
    reg clk = 0;
    always #1 clk = ~clk;

    reg  rst = 0;
    reg  in_valid = 0;
    reg  signed [15:0] in_data = 0;
    wire in_ready;

    wire out_valid;
    wire signed [15:0] out_data;

    fir #(
        .ORDER(4),  // order 4 => 5 taps
        .COEF_FILE("fir_test.N5.Q1015.memb"),
        .QIN(1015),
        .QCOEF(1015),
        .QOUT(1015)
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data(in_data),
        .out_valid(out_valid),
        .out_data(out_data)
    );

    integer i;
    initial begin
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // Feed a single-sample impulse an compare against the expected step response, which is the kernel itself.
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        in_data <= 32767;  // q1.15 closest to 1.0, ~0.99996948
        in_valid <= 1;
        @(negedge clk);  // clk #0
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        in_valid <= 0;
        @(negedge clk);  // clk #1
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #2
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #3
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #4
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #5
        `REQUIRE(in_ready);  // READY TO ACCEPT NEW INPUT, but the result is still being computed
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #6
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #7
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #8
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #8
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #10
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);  // clk #11
        `REQUIRE(in_ready);
        `REQUIRE(out_valid);
        `REQUIRE(out_data === 16'h4000);  // 1st coefficient

        // Feed N zeroes and observe the step response settling to zero.
        // Second sample, first zero.
        in_data <= 0;
        in_valid <= 1;
        @(negedge clk);  // latch the input sample
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        in_valid <= 0;
        repeat (4) @(negedge clk);
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        in_valid <= 1;   // next input sample immediately
        @(negedge clk);  // output is now valid, new sample accepted
        in_valid <= 0;
        repeat (4) @(negedge clk);
        `REQUIRE(!in_ready);  // Already accepted the next input sample while outputting the previous result.
        `REQUIRE(!out_valid);
        @(negedge clk);
        `REQUIRE(in_ready);
        `REQUIRE(out_valid);
        `REQUIRE(out_data === 16'h0000);  // 2nd coefficient

        // Third sample.
        `REQUIRE(in_ready);
        `REQUIRE(out_valid);
        in_valid <= 1;
        @(negedge clk);
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);
        in_valid <= 0;
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        repeat (3) @(negedge clk);
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        @(negedge clk);
        `REQUIRE(in_ready);
        `REQUIRE(out_valid);
        `REQUIRE(out_data === 16'h199a);  // 3rd coefficient

        // Fourth sample.
        `REQUIRE(in_ready);
        `REQUIRE(out_valid);
        in_valid <= 1;
        @(negedge clk);
        in_valid <= 0;
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        repeat (3) @(negedge clk);
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        repeat (2) @(negedge clk);
        `REQUIRE(in_ready);
        `REQUIRE(out_valid);
        `REQUIRE(out_data === 16'h2666);  // 4th coefficient

        // Fifth sample. This time, we don't feed the next sample yet.
        repeat (4) @(negedge clk);
        `REQUIRE(in_ready);         // No new sample is provided, it will stay up.
        `REQUIRE(!out_valid);
        repeat (1) @(negedge clk);
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        repeat (1) @(negedge clk);
        `REQUIRE(in_ready);
        `REQUIRE(out_valid);
        `REQUIRE(out_data === 16'h9235);  // 5th coefficient (negative)

        // Sixth sample, now the history is all zeroes, we should get zero output regardless of the kernel.
        repeat (5) @(negedge clk);  // Nothing is happening because we didn't provide a new input sample.
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);
        in_valid <= 1;
        @(negedge clk);             // latch the input sample
        in_valid <= 0;
        `REQUIRE(!in_ready);
        `REQUIRE(!out_valid);
        repeat (11) @(negedge clk);
        `REQUIRE(in_ready);
        `REQUIRE(out_valid);
        @(negedge clk);
        `REQUIRE(in_ready);
        `REQUIRE(!out_valid);       // Output still valid.
        `REQUIRE(out_data === 16'h0000);

        $finish;
    end

    initial begin
        $dumpfile("fir_tb.vcd");
        $dumpvars(0, fir_tb);
    end

endmodule
