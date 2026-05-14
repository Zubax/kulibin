// iverilog -Wall -Wno-timescale -y../hdl zkf_div_min_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module zkf_div_min_tb;
    localparam WEXP = 2;
    localparam WMAN = 4;
    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;
    localparam QFRAC_BASE = WMAN + 4;
    localparam QFRAC = QFRAC_BASE + (QFRAC_BASE % 2);
    localparam LATENCY = (QFRAC / 2) + 4;
    localparam Q = 8;

    localparam integer BIAS = (1 << (WEXP - 1)) - 1;
    localparam integer EXP_INF_INT = (1 << WEXP) - 1;
    localparam integer EXP_MAX_FINITE_INT = EXP_INF_INT - 1;
    localparam integer FRAC_MAX_INT = (1 << WFRAC) - 1;
    localparam integer CASE_COUNT = (1 << WFULL) * (1 << WFULL);
    localparam integer CLASS_ZERO = 0;
    localparam integer CLASS_FINITE = 1;
    localparam integer CLASS_INF = 2;

    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg [WFULL-1:0] a = 0;
    reg [WFULL-1:0] b = 0;

    wire out_valid;
    wire [WFULL-1:0] q;
    wire div0;

    reg expected_valid_pipe [0:LATENCY-1];
    reg [WFULL-1:0] expected_q_pipe [0:LATENCY-1];
    reg expected_div0_pipe [0:LATENCY-1];

    integer a_i;
    integer b_i;
    integer pipe_i;
    integer flush_i;
    integer reset_i;
    integer cases_checked = 0;
    integer outputs_checked = 0;

    zkf_div #(
        .WEXP(WEXP),
        .WMAN(WMAN)
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .a(a),
        .b(b),
        .out_valid(out_valid),
        .q(q),
        .div0(div0)
    );

    task automatic clear_model;
        begin
            for (pipe_i = 0; pipe_i < LATENCY; pipe_i = pipe_i + 1) begin
                expected_valid_pipe[pipe_i] = 1'b0;
                expected_q_pipe[pipe_i] = 0;
                expected_div0_pipe[pipe_i] = 1'b0;
            end
        end
    endtask

    task automatic tick;
        input expected_valid_in;
        input [WFULL-1:0] expected_q_in;
        input expected_div0_in;
        begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === expected_valid_pipe[LATENCY-1]);
            if (expected_valid_pipe[LATENCY-1]) begin
                `REQUIRE(q === expected_q_pipe[LATENCY-1]);
                `REQUIRE(div0 === expected_div0_pipe[LATENCY-1]);
                outputs_checked = outputs_checked + 1;
            end
            for (pipe_i = LATENCY - 1; pipe_i > 0; pipe_i = pipe_i - 1) begin
                expected_valid_pipe[pipe_i] = expected_valid_pipe[pipe_i-1];
                expected_q_pipe[pipe_i] = expected_q_pipe[pipe_i-1];
                expected_div0_pipe[pipe_i] = expected_div0_pipe[pipe_i-1];
            end
            expected_valid_pipe[0] = expected_valid_in;
            expected_q_pipe[0] = expected_q_in;
            expected_div0_pipe[0] = expected_div0_in;
        end
    endtask

    task automatic decode_abs_q;
        input [WFULL-1:0] x;
        output reg x_sign;
        output integer x_class;
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
                x_class = CLASS_ZERO;
                x_abs_q = 0;
            end else if (x_exp == EXP_INF_INT) begin
                x_class = CLASS_INF;
                x_abs_q = 0;
            end else begin
                x_class = CLASS_FINITE;
                x_sig = (1 << WFRAC) + x_frac;
                x_shift = Q + x_exp - BIAS - WFRAC;
                x_abs_q = x_sig << x_shift;
            end
        end
    endtask

    task automatic pack_div_abs_q;
        input in_sign;
        input integer numerator_q;
        input integer denominator_q;
        output reg [WFULL-1:0] expected_q;

        integer candidate_q;
        integer candidate_sig;
        integer distance;
        integer best_distance;
        integer best_sig_lsb;
        integer exp_field;
        integer frac_field;
        integer candidate_shift;
        integer target_q_numerator;
        reg [WEXP-1:0] candidate_exp_bits;
        reg [WMAN-2:0] candidate_frac_bits;
        reg [WFULL-1:0] candidate_y;
        begin
            expected_q = 0;

            if (numerator_q >= denominator_q) begin
                target_q_numerator = numerator_q << Q;
                best_distance = 32'h7fffffff;
                best_sig_lsb = 1;
                for (exp_field = 1; exp_field <= EXP_MAX_FINITE_INT; exp_field = exp_field + 1) begin
                    for (frac_field = 0; frac_field <= FRAC_MAX_INT; frac_field = frac_field + 1) begin
                        candidate_sig = (1 << WFRAC) + frac_field;
                        candidate_shift = Q + exp_field - BIAS - WFRAC;
                        candidate_q = candidate_sig << candidate_shift;
                        distance = target_q_numerator - (candidate_q * denominator_q);
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
                            expected_q = candidate_y;
                        end
                    end
                end

                candidate_sig = 1 << WFRAC;
                candidate_shift = Q + (EXP_MAX_FINITE_INT + 1) - BIAS - WFRAC;
                candidate_q = candidate_sig << candidate_shift;
                distance = target_q_numerator - (candidate_q * denominator_q);
                if (distance < 0) begin
                    distance = -distance;
                end
                candidate_y = {in_sign, {WEXP{1'b1}}, {WFRAC{1'b0}}};
                if (
                    (distance < best_distance) ||
                    ((distance == best_distance) && ((candidate_sig & 1) == 0) && best_sig_lsb)
                ) begin
                    expected_q = candidate_y;
                end
            end
        end
    endtask

    task automatic div_oracle;
        input [WFULL-1:0] in_a;
        input [WFULL-1:0] in_b;
        output reg [WFULL-1:0] expected_q;
        output reg expected_div0;

        reg a_sign;
        reg b_sign;
        integer a_class;
        integer b_class;
        integer a_abs_q;
        integer b_abs_q;
        begin
            decode_abs_q(in_a, a_sign, a_class, a_abs_q);
            decode_abs_q(in_b, b_sign, b_class, b_abs_q);
            expected_div0 = b_class == CLASS_ZERO;

            if (a_class == CLASS_ZERO) begin
                expected_q = {WFULL{1'b0}};
            end else if (b_class == CLASS_ZERO) begin
                expected_q = {a_sign, {WEXP{1'b1}}, {WFRAC{1'b0}}};
            end else if (b_class == CLASS_INF) begin
                expected_q = {WFULL{1'b0}};
            end else if (a_class == CLASS_INF) begin
                expected_q = {a_sign ^ b_sign, {WEXP{1'b1}}, {WFRAC{1'b0}}};
            end else begin
                pack_div_abs_q(a_sign ^ b_sign, a_abs_q, b_abs_q, expected_q);
            end
        end
    endtask

    task automatic drive_and_check;
        input valid_value;
        input [WFULL-1:0] a_value;
        input [WFULL-1:0] b_value;

        reg [WFULL-1:0] expected_q;
        reg expected_div0;
        begin
            in_valid = valid_value;
            a = a_value;
            b = b_value;
            div_oracle(a_value, b_value, expected_q, expected_div0);
            tick(valid_value, expected_q, expected_div0);
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

        drive_and_check(1'b0, 6'b1_00_111, 6'b0_11_111);

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
        $display("checked %0d exhaustive minimum-format divider cases", cases_checked);
        $finish;
    end
endmodule

`default_nettype wire
