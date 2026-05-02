/// Impulse-response testbench for the CIC decimator.
/// Run via `fusesoc run --target=sim_cic_decimator_impulse zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_impulse_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam R = 8;
    localparam N = 3;
    localparam W = 16;
    localparam RUN_PERIODS = 8;
    localparam RUN_CYCLES = R * RUN_PERIODS + N;

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

    reg signed [W-1:0] model_integrator [0:N-1];
    reg signed [W-1:0] model_integrator_next [0:N-1];
    reg signed [W-1:0] model_comb_y [0:N-1];
    reg signed [W-1:0] model_comb_y_next [0:N-1];
    reg signed [W-1:0] model_comb_z [0:N-1];
    reg signed [W-1:0] model_comb_z_next [0:N-1];
    reg signed [W-1:0] model_comb_x [0:N-1];
    reg [N-1:0] model_in_valid_pipe = 0;
    reg [N-1:0] model_in_valid_pipe_next = 0;
    reg [N-1:0] model_comb_enable;
    reg [N-1:0] model_pipe = 0;
    reg [N-1:0] model_pipe_next = 0;
    reg model_out_valid = 0;
    reg signed [W-1:0] model_out_data = 0;

    integer cycle = 0;
    integer stage = 0;
    integer out_count = 0;
    integer nonzero_count = 0;
    reg decimate_sample = 0;
    reg signed [W-1:0] input_sample = 0;

    // Independent reference: coefficients of (1 + z^-1 + ... + z^-7)^3 sampled at high-rate phase 4.
    function automatic signed [W-1:0] expected_impulse_response;
        input integer index;
        begin
            case (index)
                0: expected_impulse_response = 16'sd15;
                1: expected_impulse_response = 16'sd46;
                2: expected_impulse_response = 16'sd3;
                default: expected_impulse_response = 16'sd0;
            endcase
        end
    endfunction

    task automatic reset_model;
        begin
            model_pipe = 0;
            model_pipe_next = 0;
            model_in_valid_pipe = 0;
            model_in_valid_pipe_next = 0;
            model_out_valid = 0;
            model_out_data = 0;
            for (stage = 0; stage < N; stage = stage + 1) begin
                model_integrator[stage] = 0;
                model_integrator_next[stage] = 0;
                model_comb_y[stage] = 0;
                model_comb_y_next[stage] = 0;
                model_comb_z[stage] = 0;
                model_comb_z_next[stage] = 0;
                model_comb_x[stage] = 0;
                model_comb_enable[stage] = 1'b0;
            end
        end
    endtask

    task automatic model_tick;
        input signed [W-1:0] sample;
        input sample_valid;
        input decimation;
        begin
            for (stage = 0; stage < N; stage = stage + 1) begin
                model_integrator_next[stage] = model_integrator[stage];
                model_comb_y_next[stage] = model_comb_y[stage];
                model_comb_z_next[stage] = model_comb_z[stage];
            end

            if (sample_valid) begin
                model_integrator_next[0] = model_integrator[0] + sample;
            end
            for (stage = 1; stage < N; stage = stage + 1) begin
                if (model_in_valid_pipe[stage-1]) begin
                    model_integrator_next[stage] = model_integrator[stage] + model_integrator[stage-1];
                end
            end

            model_in_valid_pipe_next[0] = sample_valid;
            for (stage = 1; stage < N; stage = stage + 1) begin
                model_in_valid_pipe_next[stage] = model_in_valid_pipe[stage-1];
            end

            model_comb_x[0] = model_integrator[N-1];
            for (stage = 1; stage < N; stage = stage + 1) begin
                model_comb_x[stage] = model_comb_y[stage-1];
            end

            model_comb_enable[0] = decimation;
            for (stage = 1; stage < N; stage = stage + 1) begin
                model_comb_enable[stage] = model_pipe[stage-1];
            end

            for (stage = 0; stage < N; stage = stage + 1) begin
                if (model_comb_enable[stage]) begin
                    model_comb_y_next[stage] = model_comb_x[stage] - model_comb_z[stage];
                    model_comb_z_next[stage] = model_comb_x[stage];
                end
            end

            model_pipe_next[0] = decimation;
            for (stage = 1; stage < N; stage = stage + 1) begin
                model_pipe_next[stage] = model_pipe[stage-1];
            end

            for (stage = 0; stage < N; stage = stage + 1) begin
                model_integrator[stage] = model_integrator_next[stage];
                model_comb_y[stage] = model_comb_y_next[stage];
                model_comb_z[stage] = model_comb_z_next[stage];
                model_in_valid_pipe[stage] = model_in_valid_pipe_next[stage];
                model_pipe[stage] = model_pipe_next[stage];
            end

            model_out_valid = model_pipe[N-1];
            model_out_data = model_comb_y[N-1];
        end
    endtask

    initial begin
        `REQUIRE(R >= N);
        reset_model;

        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        for (cycle = 0; cycle < RUN_CYCLES; cycle = cycle + 1) begin
            input_sample = (cycle == 0) ? 16'sd1 : 16'sd0;
            decimate_sample = (cycle < (R * RUN_PERIODS)) && (((cycle + 1) % R) == 0);
            in_valid <= (cycle < (R * RUN_PERIODS));
            in_data <= input_sample;
            decimate <= decimate_sample;

            @(posedge clk);
            model_tick(input_sample, (cycle < (R * RUN_PERIODS)), decimate_sample);
            #1;

            `REQUIRE(out_valid == model_out_valid);
            if (model_out_valid) begin
                `REQUIRE(out_data == model_out_data);
                `REQUIRE(out_data == expected_impulse_response(out_count));
                if (out_data != 0) begin
                    nonzero_count = nonzero_count + 1;
                end
                $display("out[%0d] = %0d", out_count, out_data);
                out_count = out_count + 1;
            end

            @(negedge clk);
        end

        in_valid <= 1'b0;
        decimate <= 1'b0;
        in_data <= 0;

        `REQUIRE(out_count == RUN_PERIODS);
        `REQUIRE(nonzero_count == 3);

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_impulse_tb.vcd");
        $dumpvars();
    end
endmodule
