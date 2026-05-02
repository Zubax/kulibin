/// Mathematical response testbench for the CIC decimator.
/// Run via `fusesoc run --target=sim_cic_decimator_response zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_response_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam R = 8;
    localparam N = 3;
    localparam W = 12;
    localparam IMPULSE_PERIODS = 8;
    localparam IMPULSE_CYCLES = R * IMPULSE_PERIODS + N;
    localparam RESPONSE_LAST = N * (R - 1);
    localparam RESPONSE_PHASE = R - 1 - N;
    localparam RESPONSE_GAIN = R ** (N - 1);
    localparam DC_PERIODS = 8;
    localparam DC_CYCLES = R * DC_PERIODS + N;

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
    reg signed [W-1:0] input_sample = 0;
    integer cycle = 0;
    integer stage = 0;
    integer out_count = 0;
    integer stable_count = 0;
    integer coeff_index = 0;
    integer response_sum = 0;
    integer response_moment = 0;

    function automatic integer binom;
        input integer n;
        input integer k;
        integer idx;
        integer acc;
        begin
            if ((k < 0) || (k > n)) begin
                binom = 0;
            end else begin
                acc = 1;
                for (idx = 1; idx <= k; idx = idx + 1) begin
                    acc = (acc * (n - k + idx)) / idx;
                end
                binom = acc;
            end
        end
    endfunction

    function automatic integer cic_coeff;
        input integer index;
        integer term;
        integer acc;
        integer limited_index;
        begin
            acc = 0;
            if ((index >= 0) && (index <= RESPONSE_LAST)) begin
                for (term = 0; term <= N; term = term + 1) begin
                    limited_index = index - term * R;
                    if (limited_index >= 0) begin
                        if ((term % 2) == 0) begin
                            acc = acc + binom(N, term) * binom(limited_index + N - 1, N - 1);
                        end else begin
                            acc = acc - binom(N, term) * binom(limited_index + N - 1, N - 1);
                        end
                    end
                end
            end
            cic_coeff = acc;
        end
    endfunction

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

    task automatic shift_expected_valid;
        begin
            for (stage = N - 1; stage > 0; stage = stage - 1) begin
                expected_valid_pipe[stage] = expected_valid_pipe[stage-1];
            end
            expected_valid_pipe[0] = decimate_sample;
        end
    endtask

    task automatic run_impulse_response;
        begin
            reset_case;
            out_count = 0;
            response_sum = 0;
            response_moment = 0;

            for (cycle = 0; cycle < IMPULSE_CYCLES; cycle = cycle + 1) begin
                input_sample = (cycle == 0) ? 12'sd1 : 12'sd0;
                decimate_sample = (cycle < (R * IMPULSE_PERIODS)) && (((cycle + 1) % R) == 0);
                in_valid <= (cycle < (R * IMPULSE_PERIODS));
                in_data <= input_sample;
                decimate <= decimate_sample;

                @(posedge clk);
                #1;

                shift_expected_valid;
                `REQUIRE(out_valid == expected_valid_pipe[N-1]);
                if (out_valid) begin
                    coeff_index = RESPONSE_PHASE + out_count * R;
                    `REQUIRE(out_data == cic_coeff(coeff_index));
                    response_sum = response_sum + out_data;
                    response_moment = response_moment + out_data * coeff_index;
                    $display("h[%0d] = %0d", coeff_index, out_data);
                    out_count = out_count + 1;
                end

                @(negedge clk);
            end

            in_valid <= 1'b0;
            decimate <= 1'b0;
            in_data <= 0;

            `REQUIRE(out_count == IMPULSE_PERIODS);
            `REQUIRE(response_sum == RESPONSE_GAIN);
            `REQUIRE((2 * response_moment) == (response_sum * N * (R - 1)));
        end
    endtask

    task automatic run_dc_case;
        input signed [W-1:0] sample;
        input signed [W-1:0] expected;
        begin
            reset_case;
            out_count = 0;
            stable_count = 0;

            for (cycle = 0; cycle < DC_CYCLES; cycle = cycle + 1) begin
                decimate_sample = (cycle < (R * DC_PERIODS)) && (((cycle + 1) % R) == 0);
                in_valid <= (cycle < (R * DC_PERIODS));
                in_data <= sample;
                decimate <= decimate_sample;

                @(posedge clk);
                #1;

                shift_expected_valid;
                `REQUIRE(out_valid == expected_valid_pipe[N-1]);
                if (out_valid) begin
                    out_count = out_count + 1;
                    if (out_count > N) begin
                        `REQUIRE(out_data == expected);
                        stable_count = stable_count + 1;
                    end
                end

                @(negedge clk);
            end

            in_valid <= 1'b0;
            decimate <= 1'b0;
            in_data <= 0;

            `REQUIRE(out_count == DC_PERIODS);
            `REQUIRE(stable_count > 0);
        end
    endtask

    initial begin
        `REQUIRE(RESPONSE_PHASE >= 0);

        run_impulse_response;
        run_dc_case(12'sd3,  12'sd1536);
        run_dc_case(-12'sd4, -12'sd2048);

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_response_tb.vcd");
        $dumpvars();
    end
endmodule
