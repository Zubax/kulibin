// iverilog -Wall -Wno-timescale -y../hdl zkf_mul_min_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module zkf_mul_min_tb;
    localparam WEXP = 2;
    localparam WMAN = 3;
    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;
    localparam LATENCY = 4;
    localparam Q = 8;

    localparam integer BIAS = (1 << (WEXP - 1)) - 1;
    localparam integer EXP_MAX_INT = (1 << WEXP) - 1;
    localparam integer FRAC_MAX_INT = (1 << WFRAC) - 1;
    localparam integer CASE_COUNT = (1 << WFULL) * (1 << WFULL);

    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg [WFULL-1:0] a = 0;
    reg [WFULL-1:0] b = 0;

    wire out_valid;
    wire [WFULL-1:0] y;
    wire saturated;

    reg expected_valid_pipe [0:LATENCY-1];
    reg [WFULL-1:0] expected_y_pipe [0:LATENCY-1];

    integer a_i;
    integer b_i;
    integer cases_checked = 0;
    integer outputs_checked = 0;
    integer pipe_i;
    integer flush_i;
    integer reset_i;

    zkf_mul #(
        .WEXP(WEXP),
        .WMAN(WMAN)
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .a(a),
        .b(b),
        .out_valid(out_valid),
        .y(y),
        .saturated(saturated)
    );

    task automatic clear_model;
        begin
            for (pipe_i = 0; pipe_i < LATENCY; pipe_i = pipe_i + 1) begin
                expected_valid_pipe[pipe_i] = 1'b0;
                expected_y_pipe[pipe_i] = 0;
            end
        end
    endtask

    task automatic decode_abs_q;
        input [WFULL-1:0] x;
        output reg x_sign;
        output integer x_abs_q;

        integer x_exp;
        integer x_frac;
        integer x_sig;
        integer x_shift;
        begin
            x_sign = x[WFULL-1];
            x_exp = x[WFRAC+:WEXP];
            x_frac = x[WFRAC-1:0];
            if (x_exp == 0) begin
                x_abs_q = 0;
            end else begin
                x_sig = (1 << WFRAC) + x_frac;
                x_shift = Q + x_exp - BIAS - WFRAC;
                x_abs_q = x_sig << x_shift;
            end
        end
    endtask

    task automatic pack_abs_q;
        input in_sign;
        input integer input_q;
        output reg [WFULL-1:0] expected_y;

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
        begin
            expected_y = 0;

            if (input_q >= (1 << Q)) begin
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

                        if (
                            (distance < best_distance) ||
                            ((distance == best_distance) && ((candidate_sig & 1) == 0) && best_sig_lsb)
                        ) begin
                            best_distance = distance;
                            best_sig_lsb = candidate_sig & 1;
                            expected_y = candidate_y;
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
                if (
                    (distance < best_distance) ||
                    ((distance == best_distance) && ((candidate_sig & 1) == 0) && best_sig_lsb)
                ) begin
                    expected_y = candidate_y;
                end
            end
        end
    endtask

    task automatic mul_oracle;
        input [WFULL-1:0] in_a;
        input [WFULL-1:0] in_b;
        output reg [WFULL-1:0] expected_y;

        reg a_sign;
        reg b_sign;
        integer a_abs_q;
        integer b_abs_q;
        integer product_q;
        begin
            decode_abs_q(in_a, a_sign, a_abs_q);
            decode_abs_q(in_b, b_sign, b_abs_q);
            product_q = (a_abs_q * b_abs_q) >> Q;
            pack_abs_q(a_sign ^ b_sign, product_q, expected_y);
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
        input [WFULL-1:0] a_value;
        input [WFULL-1:0] b_value;

        reg [WFULL-1:0] expected_y;
        begin
            in_valid = valid_value;
            a = a_value;
            b = b_value;
            mul_oracle(a_value, b_value, expected_y);
            tick(valid_value, expected_y);
            if (valid_value) begin
                cases_checked = cases_checked + 1;
            end
        end
    endtask

    initial begin
        clear_model();

        in_valid = 1'b1;
        a = {WFULL{1'b1}};
        b = {WFULL{1'b1}};
        for (reset_i = 0; reset_i < LATENCY + 2; reset_i = reset_i + 1) begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === 1'b0);
        end

        rst = 1'b0;
        clear_model();

        drive_and_check(1'b0, 5'b1_00_11, 5'b0_11_11);

        for (a_i = 0; a_i < (1 << WFULL); a_i = a_i + 1) begin
            for (b_i = 0; b_i < (1 << WFULL); b_i = b_i + 1) begin
                drive_and_check(1'b1, a_i[WFULL-1:0], b_i[WFULL-1:0]);
            end
        end

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            drive_and_check(1'b0, 0, 0);
        end

        `REQUIRE(cases_checked == CASE_COUNT);
        `REQUIRE(outputs_checked == cases_checked);
        $display("checked %0d exhaustive minimum-format multiplier cases", cases_checked);
        $finish;
    end
endmodule

`default_nettype wire
