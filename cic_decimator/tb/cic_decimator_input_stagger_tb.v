/// Sparse-input valid-staggering testbench for the CIC decimator.
/// Run via `fusesoc run --target=sim_cic_decimator_input_stagger zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_input_stagger_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam N = 3;
    localparam W = 16;
    localparam RUN_CYCLES = 2 * N + 4;

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
    integer out_count = 0;
    integer expected_out_cycle = 0;
    integer decimate_offset = 0;
    reg signed [W-1:0] expected_out_data = 0;

    task automatic reset_case;
        begin
            rst <= 1'b1;
            in_valid <= 1'b0;
            decimate <= 1'b0;
            in_data <= 0;
            expected_valid_pipe = 0;
            repeat (2) @(negedge clk);
            rst <= 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic run_case;
        input integer case_decimate_offset;
        input signed [W-1:0] case_expected_out_data;
        begin
            reset_case;
            out_count = 0;
            expected_out_cycle = case_decimate_offset + N - 1;

            for (cycle = 0; cycle < RUN_CYCLES; cycle = cycle + 1) begin
                decimate_sample = (cycle == case_decimate_offset);
                in_valid <= (cycle == 0);
                in_data <= (cycle == 0) ? 16'sd1 : 16'sd0;
                decimate <= decimate_sample;

                @(posedge clk);
                #1;

                for (stage = N - 1; stage > 0; stage = stage - 1) begin
                    expected_valid_pipe[stage] = expected_valid_pipe[stage-1];
                end
                expected_valid_pipe[0] = decimate_sample;

                `REQUIRE(out_valid == expected_valid_pipe[N-1]);
                if (out_valid) begin
                    out_count = out_count + 1;
                    `REQUIRE(cycle == expected_out_cycle);
                    `REQUIRE(out_data == case_expected_out_data);
                end

                @(negedge clk);
            end

            `REQUIRE(out_count == 1);
        end
    endtask

    initial begin
        decimate_offset = N - 1;
        expected_out_data = 16'sd0;
        run_case(decimate_offset, expected_out_data);

        decimate_offset = N;
        expected_out_data = 16'sd1;
        run_case(decimate_offset, expected_out_data);

        in_valid <= 1'b0;
        decimate <= 1'b0;
        in_data <= 0;

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_input_stagger_tb.vcd");
        $dumpvars();
    end
endmodule
