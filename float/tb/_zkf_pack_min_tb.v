// iverilog -Wall -Wno-timescale -y../hdl _zkf_pack_min_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module _zkf_pack_min_tb;
    localparam WEXP = 2;
    localparam WMAN = 4;
    localparam WMAG = 8;
    localparam WSCALE = 3;
    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;
    localparam LATENCY = 1;

    localparam integer BIAS = (1 << (WEXP - 1)) - 1;
    localparam integer EXP_INF_INT = (1 << WEXP) - 1;
    localparam integer EXP_MAX_FINITE_INT = EXP_INF_INT - 1;
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

    reg expected_valid_pipe [0:LATENCY-1];
    reg [WFULL-1:0] expected_y_pipe [0:LATENCY-1];

    integer cases_checked = 0;
    integer outputs_checked = 0;
    integer pipe_i;
    integer sign_i;
    integer mag_i;
    integer scale_i;
    integer flush_i;
    reg [WFULL-1:0] directed_y;

    _zkf_pack_tb_wrapper #(
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
        .y(y)
    );

    task automatic clear_model;
        begin
            for (pipe_i = 0; pipe_i < LATENCY; pipe_i = pipe_i + 1) begin
                expected_valid_pipe[pipe_i] = 1'b0;
                expected_y_pipe[pipe_i] = 0;
            end
        end
    endtask

    task automatic pack_oracle;
        input in_sign;
        input [WMAG-1:0] in_mag;
        input signed [WSCALE-1:0] in_scale;
        output reg [WFULL-1:0] expected_y;

        integer scan_i;
        integer log2_mag;
        integer exp_unbiased_i;
        integer exp_field;
        integer frac_field;
        integer shift;
        integer significand_i;
        integer guard_i;
        integer round_i;
        integer sticky_i;
        integer tail_mask;
        reg [WEXP-1:0] exp_bits;
        reg [WFRAC-1:0] frac_bits;
        begin
            expected_y = 0;

            if (in_mag != 0) begin
                log2_mag = 0;
                for (scan_i = 0; scan_i < WMAG; scan_i = scan_i + 1) begin
                    if (in_mag[scan_i]) begin
                        log2_mag = scan_i;
                    end
                end

                exp_unbiased_i = in_scale + log2_mag;
                if (log2_mag >= WFRAC) begin
                    shift = log2_mag - WFRAC;
                    significand_i = in_mag >> shift;
                    guard_i = (shift >= 1) ? ((in_mag >> (shift - 1)) & 1) : 0;
                    round_i = (shift >= 2) ? ((in_mag >> (shift - 2)) & 1) : 0;
                    if (shift >= 3) begin
                        tail_mask = (1 << (shift - 2)) - 1;
                        sticky_i = ((in_mag & tail_mask) != 0);
                    end else begin
                        sticky_i = 0;
                    end
                end else begin
                    shift = WFRAC - log2_mag;
                    significand_i = in_mag << shift;
                    guard_i = 0;
                    round_i = 0;
                    sticky_i = 0;
                end

                if (guard_i && (round_i || sticky_i || (significand_i & 1))) begin
                    significand_i = significand_i + 1;
                end
                if (significand_i >= (1 << WMAN)) begin
                    significand_i = significand_i >> 1;
                    exp_unbiased_i = exp_unbiased_i + 1;
                end

                if (exp_unbiased_i > (EXP_MAX_FINITE_INT - BIAS)) begin
                    expected_y = {in_sign, {WEXP{1'b1}}, {WFRAC{1'b0}}};
                end else if (exp_unbiased_i >= (1 - BIAS)) begin
                    exp_field = exp_unbiased_i + BIAS;
                    frac_field = significand_i & FRAC_MAX_INT;
                    exp_bits = exp_field[WEXP-1:0];
                    frac_bits = frac_field[WFRAC-1:0];
                    expected_y = {in_sign, exp_bits, frac_bits};
                end
            end
        end
    endtask

    task automatic tick;
        input expected_valid_in;
        input [WFULL-1:0] expected_y_in;
        begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === expected_valid_pipe[LATENCY-1]);
            if (expected_valid_pipe[LATENCY-1]) begin
                `REQUIRE(y === expected_y_pipe[LATENCY-1]);
                outputs_checked = outputs_checked + 1;
            end
            for (pipe_i = LATENCY - 1; pipe_i > 0; pipe_i = pipe_i - 1) begin
                expected_valid_pipe[pipe_i] = expected_valid_pipe[pipe_i-1];
                expected_y_pipe[pipe_i] = expected_y_pipe[pipe_i-1];
            end
            expected_valid_pipe[0] = expected_valid_in;
            expected_y_pipe[0] = expected_y_in;
        end
    endtask

    task automatic drive_and_check;
        input valid_value;
        input sign_value;
        input [WMAG-1:0] mag_value;
        input signed [WSCALE-1:0] scale_value;
        reg [WFULL-1:0] expected_y;
        begin
            in_valid = valid_value;
            sign = sign_value;
            mag = mag_value;
            scale = scale_value;
            pack_oracle(sign_value, mag_value, scale_value, expected_y);
            tick(valid_value, expected_y);
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
        end

        rst = 1'b0;
        clear_model();

        pack_oracle(1'b1, 8'd0, 3'sd3, directed_y);
        `REQUIRE(directed_y === 6'b0_00_000);
        pack_oracle(1'b0, 8'd1, -1, directed_y);
        `REQUIRE(directed_y === 6'b0_00_000);
        pack_oracle(1'b0, 8'd1, 3'sd0, directed_y);
        `REQUIRE(directed_y === 6'b0_01_000);
        pack_oracle(1'b0, 8'd9, -3, directed_y);
        `REQUIRE(directed_y === 6'b0_01_001);
        pack_oracle(1'b0, 8'd11, -3, directed_y);
        `REQUIRE(directed_y === 6'b0_01_011);
        pack_oracle(1'b0, 8'd31, -4, directed_y);
        `REQUIRE(directed_y === 6'b0_10_000);
        pack_oracle(1'b1, 8'd15, -1, directed_y);
        `REQUIRE(directed_y === 6'b1_11_000);

        drive_and_check(1'b0, 1'b1, 8'd255, 3'sd3);
        drive_and_check(1'b1, 1'b1, 8'd0, 3'sd3);
        drive_and_check(1'b0, 1'b0, 8'd255, -4);
        drive_and_check(1'b1, 1'b0, 8'd1, -1);
        drive_and_check(1'b1, 1'b0, 8'd1, 3'sd0);
        drive_and_check(1'b1, 1'b0, 8'd9, -3);
        drive_and_check(1'b1, 1'b0, 8'd11, -3);
        drive_and_check(1'b1, 1'b0, 8'd31, -4);
        drive_and_check(1'b1, 1'b1, 8'd15, -1);

        for (sign_i = 0; sign_i < 2; sign_i = sign_i + 1) begin
            for (mag_i = 0; mag_i < (1 << WMAG); mag_i = mag_i + 1) begin
                for (scale_i = -4; scale_i < 4; scale_i = scale_i + 1) begin
                    drive_and_check(1'b1, sign_i != 0, mag_i, scale_i);
                end
            end
        end

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            drive_and_check(1'b0, 1'b0, 8'd0, 3'sd0);
        end

        `REQUIRE(cases_checked == CASE_COUNT + 7);
        `REQUIRE(outputs_checked == cases_checked);
        $display("checked %0d valid minimum-format cases", cases_checked);
        $finish;
    end
endmodule

`default_nettype wire
