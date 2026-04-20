/// iverilog -Wall -Wno-timescale -y. cic_decimator_tb.v && vvp a.out

`default_nettype none
`timescale 1ns/1ns
`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam R = 16;
    localparam N = 2;
    localparam W = 12;

    reg rst = 0;
    reg in_valid = 0;
    reg decimate = 0;
    reg  signed [W-1:0] in_data = 0;
    wire out_valid;
    wire signed [W-1:0] out_data;

    cic_decimator #(.W(W), .N(N)) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_data(in_data),
        .decimate(decimate),
        .out_valid(out_valid),
        .out_data(out_data)
    );

    integer sample_count = 0;
    initial begin
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // Feed +1, expect the output to converge to 1*R^N = +256.
        sample_count = 0;
        while (sample_count < R * 5) begin
            in_data <= +1;
            decimate <= ((sample_count + 1) % R == 0);  // expect output on next clk cycle
            in_valid <= 1;
            @(negedge clk);
            decimate <= 0;
            in_valid <= 0;
            @(negedge clk);
            sample_count = sample_count + 1;
        end
        `REQUIRE(out_data == +256);

        // Feed -3, expect the output to converge to -3*R^N = -768.
        sample_count = 0;
        while (sample_count < R * 5) begin
            in_data <= -3;
            decimate <= ((sample_count + 1) % R == 0);
            in_valid <= 1;
            @(negedge clk);
            decimate <= 0;
            in_valid <= 0;
            @(negedge clk);
            sample_count = sample_count + 1;
        end
        `REQUIRE(out_data == -768);

        // Feed +4, expect the output to converge to +4*R^N = +1024. This is the maximum for signed 12-bit.
        sample_count = 0;
        while (sample_count < R * 5) begin
            in_data <= +4;
            decimate <= ((sample_count + 1) % R == 0);
            in_valid <= 1;
            @(negedge clk);
            decimate <= 0;
            in_valid <= 0;
            @(negedge clk);
            sample_count = sample_count + 1;
        end
        `REQUIRE(out_data == +1024);

        @(negedge clk);
        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_tb.vcd");
        $dumpvars();
    end
endmodule
