/// Valid-staggering testbench for the CIC decimator.
/// Run via `fusesoc run --target=sim_cic_decimator_stagger zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_stagger_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam R = 8;
    localparam N = 3;
    localparam W = 16;
    localparam RUN_PERIODS = 12;
    localparam RUN_CYCLES = R * RUN_PERIODS + N;
    localparam signed [W-1:0] INPUT_DATA = 2;
    localparam signed [W-1:0] EXPECTED_GAIN = INPUT_DATA * R * R * R;

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

    reg [N-1:0] expected_valid_pipe = 0;
    reg decimate_sample = 0;
    integer cycle = 0;
    integer stage = 0;
    integer decimate_count = 0;
    integer out_count = 0;
    integer settled_count = 0;

    initial begin
        `REQUIRE(R >= N);

        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        for (cycle = 0; cycle < RUN_CYCLES; cycle = cycle + 1) begin
            decimate_sample = (cycle < (R * RUN_PERIODS)) && (((cycle + 1) % R) == 0);
            in_valid <= (cycle < (R * RUN_PERIODS));
            in_data <= INPUT_DATA;
            decimate <= decimate_sample;

            @(posedge clk);
            #1;

            if (decimate_sample) begin
                decimate_count = decimate_count + 1;
            end
            for (stage = N - 1; stage > 0; stage = stage - 1) begin
                expected_valid_pipe[stage] = expected_valid_pipe[stage-1];
            end
            expected_valid_pipe[0] = decimate_sample;

            `REQUIRE(out_valid == expected_valid_pipe[N-1]);
            if (out_valid) begin
                out_count = out_count + 1;
                if (out_count > N) begin
                    `REQUIRE(out_data == EXPECTED_GAIN);
                    settled_count = settled_count + 1;
                end
            end

            @(negedge clk);
        end

        in_valid <= 1'b0;
        decimate <= 1'b0;
        in_data <= 0;

        `REQUIRE(decimate_count == RUN_PERIODS);
        `REQUIRE(out_count == RUN_PERIODS);
        `REQUIRE(settled_count > 0);

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_stagger_tb.vcd");
        $dumpvars();
    end
endmodule
