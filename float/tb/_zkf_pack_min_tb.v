// iverilog -Wall -Wno-timescale -y../hdl _zkf_pack_min_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module _zkf_pack_min_tb;
    localparam WEXP = 2;
    localparam WMAN = 3;
    localparam WMAG = 6;
    localparam WSCALE = 3;
    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;
    localparam LATENCY = 4;
    localparam Q = 8;

    localparam integer BIAS = (1 << (WEXP - 1)) - 1;
    localparam integer EXP_MAX_INT = (1 << WEXP) - 1;
    localparam integer FRAC_MAX_INT = (1 << WFRAC) - 1;
    localparam integer CASE_COUNT = 2 * (1 << WMAG) * (1 << WSCALE);

    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg sign = 1'b0;
    reg [WMAG-1:0] mag = 0;
    reg signed [WSCALE-1:0] scale = 0;

    wire out_valid;
    wire [WFULL-1:0] y;
    wire saturated;

    reg expected_valid_pipe [0:LATENCY-1];
    reg [WFULL-1:0] expected_y_pipe [0:LATENCY-1];
    reg expected_saturated_pipe [0:LATENCY-1];

    integer cases_checked = 0;
    integer outputs_checked = 0;
    integer pipe_i;
    integer sign_i;
    integer mag_i;
    integer scale_i;
    integer flush_i;
    reg [WFULL-1:0] directed_y;
    reg directed_saturated;

    _zkf_pack #(
        .WEXP(WEXP),
        .WMAN(WMAN),
        .WMAG(WMAG),
        .WSCALE(WSCALE)
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .sign(sign),
        .mag(mag),
        .scale(scale),
        .out_valid(out_valid),
        .y(y),
        .saturated(saturated)
    );

    task automatic clear_model;
        begin
            for (pipe_i = 0; pipe_i < LATENCY; pipe_i = pipe_i + 1) begin
                expected_valid_pipe[pipe_i] = 1'b0;
                expected_y_pipe[pipe_i] = 0;
                expected_saturated_pipe[pipe_i] = 1'b0;
            end
        end
    endtask

    task automatic pack_oracle;
        input in_sign;
        input [WMAG-1:0] in_mag;
        input signed [WSCALE-1:0] in_scale;
        output reg [WFULL-1:0] expected_y;
        output reg expected_saturated;

        integer input_q;
        integer candidate_q;
        integer candidate_sig;
        integer distance;
        integer best_distance;
        integer best_sig_lsb;
        integer exp_field;
        integer frac_field;
        integer candidate_shift;
        reg [WEXP-1:0] candidate_exp_bits;
        reg [WFRAC-1:0] candidate_frac_bits;
        reg [WFULL-1:0] candidate_y;
        reg candidate_saturated;
        begin
            expected_y = 0;
            expected_saturated = 1'b0;
            input_q = in_mag;
            input_q = input_q << (in_scale + Q);

            if ((in_mag != 0) && (input_q >= (1 << Q))) begin
                best_distance = 32'h7fffffff;
                best_sig_lsb = 1;
                for (exp_field = 1; exp_field <= EXP_MAX_INT; exp_field = exp_field + 1) begin
                    for (frac_field = 0; frac_field <= FRAC_MAX_INT; frac_field = frac_field + 1) begin
                        candidate_sig = (1 << WFRAC) + frac_field;
                        candidate_shift = Q + exp_field - BIAS - WFRAC;
                        candidate_q = candidate_sig << candidate_shift;
                        distance = input_q - candidate_q;
                        if (distance < 0) begin
                            distance = -distance;
                        end
                        candidate_exp_bits = exp_field;
                        candidate_frac_bits = frac_field;
                        candidate_y = {in_sign, candidate_exp_bits, candidate_frac_bits};
                        candidate_saturated = 1'b0;

                        if (
                            (distance < best_distance) ||
                            ((distance == best_distance) && ((candidate_sig & 1) == 0) && best_sig_lsb)
                        ) begin
                            best_distance = distance;
                            best_sig_lsb = candidate_sig & 1;
                            expected_y = candidate_y;
                            expected_saturated = candidate_saturated;
                        end
                    end
                end

                candidate_sig = 1 << WFRAC;
                candidate_shift = Q + (EXP_MAX_INT + 1) - BIAS - WFRAC;
                candidate_q = candidate_sig << candidate_shift;
                distance = input_q - candidate_q;
                if (distance < 0) begin
                    distance = -distance;
                end
                candidate_y = {in_sign, {WEXP{1'b1}}, {WFRAC{1'b1}}};
                candidate_saturated = 1'b1;
                if (
                    (distance < best_distance) ||
                    ((distance == best_distance) && ((candidate_sig & 1) == 0) && best_sig_lsb)
                ) begin
                    expected_y = candidate_y;
                    expected_saturated = candidate_saturated;
                end
            end
        end
    endtask

    task automatic tick;
        input expected_valid_in;
        input [WFULL-1:0] expected_y_in;
        input expected_saturated_in;
        begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === expected_valid_pipe[LATENCY-1]);
            if (expected_valid_pipe[LATENCY-1]) begin
                `REQUIRE(y === expected_y_pipe[LATENCY-1]);
                `REQUIRE(saturated === expected_saturated_pipe[LATENCY-1]);
                outputs_checked = outputs_checked + 1;
            end
            for (pipe_i = LATENCY - 1; pipe_i > 0; pipe_i = pipe_i - 1) begin
                expected_valid_pipe[pipe_i] = expected_valid_pipe[pipe_i-1];
                expected_y_pipe[pipe_i] = expected_y_pipe[pipe_i-1];
                expected_saturated_pipe[pipe_i] = expected_saturated_pipe[pipe_i-1];
            end
            expected_valid_pipe[0] = expected_valid_in;
            expected_y_pipe[0] = expected_y_in;
            expected_saturated_pipe[0] = expected_saturated_in;
        end
    endtask

    task automatic drive_and_check;
        input valid_value;
        input sign_value;
        input [WMAG-1:0] mag_value;
        input signed [WSCALE-1:0] scale_value;
        reg [WFULL-1:0] expected_y;
        reg expected_saturated;
        begin
            in_valid = valid_value;
            sign = sign_value;
            mag = mag_value;
            scale = scale_value;
            pack_oracle(sign_value, mag_value, scale_value, expected_y, expected_saturated);
            tick(valid_value, expected_y, expected_saturated);
            if (valid_value) begin
                cases_checked = cases_checked + 1;
            end
        end
    endtask

    initial begin
        clear_model();

        in_valid = 1'b1;
        sign = 1'b1;
        mag = {WMAG{1'b1}};
        scale = 3'sd3;
        repeat (3) begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === 1'b0);
            `REQUIRE(y === 0);
            `REQUIRE(saturated === 1'b0);
        end

        rst = 1'b0;
        clear_model();

        pack_oracle(1'b1, 6'd0, 3'sd3, directed_y, directed_saturated);
        `REQUIRE(directed_y === 5'b0_00_00);
        `REQUIRE(directed_saturated === 1'b0);
        pack_oracle(1'b0, 6'd1, -1, directed_y, directed_saturated);
        `REQUIRE(directed_y === 5'b0_00_00);
        `REQUIRE(directed_saturated === 1'b0);
        pack_oracle(1'b0, 6'd1, 3'sd0, directed_y, directed_saturated);
        `REQUIRE(directed_y === 5'b0_01_00);
        `REQUIRE(directed_saturated === 1'b0);
        pack_oracle(1'b0, 6'd9, -3, directed_y, directed_saturated);
        `REQUIRE(directed_y === 5'b0_01_00);
        `REQUIRE(directed_saturated === 1'b0);
        pack_oracle(1'b0, 6'd11, -3, directed_y, directed_saturated);
        `REQUIRE(directed_y === 5'b0_01_10);
        `REQUIRE(directed_saturated === 1'b0);
        pack_oracle(1'b0, 6'd15, -3, directed_y, directed_saturated);
        `REQUIRE(directed_y === 5'b0_10_00);
        `REQUIRE(directed_saturated === 1'b0);
        pack_oracle(1'b1, 6'd15, -1, directed_y, directed_saturated);
        `REQUIRE(directed_y === 5'b1_11_11);
        `REQUIRE(directed_saturated === 1'b1);

        drive_and_check(1'b0, 1'b1, 6'd63, 3'sd3);
        drive_and_check(1'b1, 1'b1, 6'd0, 3'sd3);
        drive_and_check(1'b0, 1'b0, 6'd63, -4);
        drive_and_check(1'b1, 1'b0, 6'd1, -1);
        drive_and_check(1'b1, 1'b0, 6'd1, 3'sd0);
        drive_and_check(1'b1, 1'b0, 6'd9, -3);
        drive_and_check(1'b1, 1'b0, 6'd11, -3);
        drive_and_check(1'b1, 1'b0, 6'd15, -3);
        drive_and_check(1'b1, 1'b1, 6'd15, -1);

        for (sign_i = 0; sign_i < 2; sign_i = sign_i + 1) begin
            for (mag_i = 0; mag_i < (1 << WMAG); mag_i = mag_i + 1) begin
                for (scale_i = -4; scale_i < 4; scale_i = scale_i + 1) begin
                    drive_and_check(1'b1, sign_i != 0, mag_i, scale_i);
                end
            end
        end

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            drive_and_check(1'b0, 1'b0, 6'd0, 3'sd0);
        end

        `REQUIRE(cases_checked == CASE_COUNT + 7);
        `REQUIRE(outputs_checked == cases_checked);
        $display("checked %0d valid minimum-format cases", cases_checked);
        $finish;
    end
endmodule

`default_nettype wire
