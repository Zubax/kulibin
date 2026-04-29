/// Testbench for cdc_sync. Run via `fusesoc run --target=sim zubax:kulibin:cdc_sync`.

`timescale 1ns/1ns
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module cdc_sync_tb;
    localparam W_DEFAULT = 1;
    localparam D_DEFAULT = 2;
    localparam W_WIDE    = 3;
    localparam D_WIDE    = 4;

    reg clk = 0;
    always #5 clk = !clk;

    reg                 rst        = 1;
    reg [W_DEFAULT-1:0] in_default = 0;
    reg [W_WIDE-1:0]    in_wide    = 0;

    wire [W_DEFAULT-1:0] out_default;
    wire [W_WIDE-1:0]    out_wide;

    cdc_sync #(.WIDTH(W_DEFAULT), .DEPTH(D_DEFAULT)) dut_default (
        .clk(clk),
        .rst(rst),
        .in(in_default),
        .out(out_default)
    );

    cdc_sync #(.WIDTH(W_WIDE), .DEPTH(D_WIDE)) dut_wide (
        .clk(clk),
        .rst(rst),
        .in(in_wide),
        .out(out_wide)
    );

    initial begin
        $dumpfile("cdc_sync_tb.vcd");
        $dumpvars();

        // Hold rst across several posedge clk events with in=all-ones; outputs must be 0.
        rst        = 1;
        in_default = {W_DEFAULT{1'b1}};
        in_wide    = {W_WIDE{1'b1}};
        repeat (D_WIDE + 2) @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b0}});
        `REQUIRE(out_wide    === {W_WIDE{1'b0}});

        // Release reset with in=0; outputs must stay 0.
        @(negedge clk);
        rst        = 0;
        in_default = 0;
        in_wide    = 0;
        repeat (D_WIDE + 2) @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b0}});
        `REQUIRE(out_wide    === {W_WIDE{1'b0}});

        // Step in 0 -> all-ones. dut_default (DEPTH=2) follows after 2 clocks; dut_wide (DEPTH=4) after 4.
        @(negedge clk);
        in_default = {W_DEFAULT{1'b1}};
        in_wide    = {W_WIDE{1'b1}};
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b0}});
        `REQUIRE(out_wide    === {W_WIDE{1'b0}});
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b1}});
        `REQUIRE(out_wide    === {W_WIDE{1'b0}});
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b1}});
        `REQUIRE(out_wide    === {W_WIDE{1'b0}});
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b1}});
        `REQUIRE(out_wide    === {W_WIDE{1'b1}});

        // Step in all-ones -> 0; symmetric DEPTH-cycle delay back to 0.
        @(negedge clk);
        in_default = 0;
        in_wide    = 0;
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b1}});
        `REQUIRE(out_wide    === {W_WIDE{1'b1}});
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b0}});
        `REQUIRE(out_wide    === {W_WIDE{1'b1}});
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b0}});
        `REQUIRE(out_wide    === {W_WIDE{1'b1}});
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b0}});
        `REQUIRE(out_wide    === {W_WIDE{1'b0}});

        // Per-bit isolation: bit-0 and bit-2 high, bit-1 low; each chain propagates independently.
        @(negedge clk);
        in_wide = 3'b101;
        repeat (D_WIDE) @(posedge clk); #1;
        `REQUIRE(out_wide === 3'b101);

        // Mid-flight synchronous reset: fill both chains with 1s, then assert rst for one posedge clk.
        @(negedge clk);
        in_default = {W_DEFAULT{1'b1}};
        in_wide    = 3'b111;
        repeat (D_WIDE) @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b1}});
        `REQUIRE(out_wide    === 3'b111);

        @(negedge clk);
        rst = 1;
        @(posedge clk); #1;
        `REQUIRE(out_default === {W_DEFAULT{1'b0}});
        `REQUIRE(out_wide    === {W_WIDE{1'b0}});

        $display("cdc_sync_tb: all checks passed");
        $finish;
    end
endmodule

`default_nettype wire
