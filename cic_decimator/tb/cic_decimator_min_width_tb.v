/// Minimum-width CIC decimator testbench.
/// Run via `fusesoc run --target=sim_cic_decimator_min_width zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_min_width_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam N = 1;
    localparam W = 2;
    localparam SAMPLE_COUNT = 4;
    localparam RUN_CYCLES = SAMPLE_COUNT + 1;

    reg rst = 0;
    reg in_valid = 0;
    reg decimate = 0;
    reg signed [W-1:0] in_data = 0;
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

    integer cycle = 0;
    integer out_count = 0;

    function automatic signed [W-1:0] alternating_sample;
        input integer index;
        begin
            alternating_sample = ((index % 2) == 0) ? 2'sd1 : -2'sd1;
        end
    endfunction

    task automatic reset_case;
        begin
            rst <= 1'b1;
            in_valid <= 1'b0;
            decimate <= 1'b0;
            in_data <= 0;
            repeat (2) @(negedge clk);
            rst <= 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        reset_case;

        for (cycle = 0; cycle < RUN_CYCLES; cycle = cycle + 1) begin
            in_valid <= (cycle < SAMPLE_COUNT);
            in_data <= (cycle < SAMPLE_COUNT) ? alternating_sample(cycle) : 2'sd0;
            decimate <= (cycle > 0);

            @(posedge clk);
            #1;

            `REQUIRE(out_valid == (cycle > 0));
            if (out_valid) begin
                `REQUIRE(out_data == alternating_sample(out_count));
                out_count = out_count + 1;
            end

            @(negedge clk);
        end

        in_valid <= 1'b0;
        decimate <= 1'b0;
        in_data <= 0;
        `REQUIRE(out_count == SAMPLE_COUNT);

        reset_case;
        decimate <= 1'b1;

        @(posedge clk);
        #1;
        `REQUIRE(out_valid);
        `REQUIRE(out_data == 2'sd0);

        @(negedge clk);
        decimate <= 1'b0;

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_min_width_tb.vcd");
        $dumpvars();
    end
endmodule
