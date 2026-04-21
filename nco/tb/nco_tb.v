/// Testbench for the NCO. Run via `fusesoc run --target=sim zubax:kulibin:nco`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module nco_tb;
    localparam OUTPUT_WIDTH = 2;
    localparam PHASE_ACCUMULATOR_WIDTH = 6;

    reg clk = 0;
    always #1 clk = !clk;

    reg rst = 1;
    reg [PHASE_ACCUMULATOR_WIDTH-1:0] fcw = 0;
    reg [PHASE_ACCUMULATOR_WIDTH-1:0] pcw = 0;

    wire [OUTPUT_WIDTH-1:0] out;
    nco #(OUTPUT_WIDTH, PHASE_ACCUMULATOR_WIDTH) dut (clk, rst, fcw, pcw, out);

    integer i;
    reg [OUTPUT_WIDTH-1:0] prev_out;
    reg [PHASE_ACCUMULATOR_WIDTH-1:0] prev_acc;

    initial begin
        $dumpfile("nco_tb.vcd");
        $dumpvars();

        // Hold reset for a few cycles; accumulator and output must be zero.
        repeat (3) @(negedge clk);
        `REQUIRE(dut.acc === {PHASE_ACCUMULATOR_WIDTH{1'b0}});
        `REQUIRE(out === {OUTPUT_WIDTH{1'b0}});

        // With fcw = 0, pcw = 0 the accumulator stays zero and output stays constant after deassertion.
        rst = 0;
        fcw = 0;
        pcw = 0;
        repeat (10) @(negedge clk);
        `REQUIRE(dut.acc === {PHASE_ACCUMULATOR_WIDTH{1'b0}});
        `REQUIRE(out === {OUTPUT_WIDTH{1'b0}});

        // With fcw = 1 the accumulator must strictly increase (modulo rollover) each clock.
        fcw = 1;
        @(negedge clk);
        prev_acc = dut.acc;
        for (i = 0; i < (1 << PHASE_ACCUMULATOR_WIDTH) * 2; i = i + 1) begin
            @(negedge clk);
            `REQUIRE(dut.acc === prev_acc + {{(PHASE_ACCUMULATOR_WIDTH-1){1'b0}}, 1'b1});
            prev_acc = dut.acc;
        end

        // Re-asserting reset must zero the accumulator and the output on the next edge.
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        `REQUIRE(dut.acc === {PHASE_ACCUMULATOR_WIDTH{1'b0}});
        `REQUIRE(out === {OUTPUT_WIDTH{1'b0}});

        $finish;
    end
endmodule
