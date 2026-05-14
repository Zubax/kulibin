// iverilog -Wall -Wno-timescale -y../hdl zkf_div_manual_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module zkf_div_manual_tb;
    localparam WEXP = 8;
    localparam WMAN = 24;
    localparam WFULL = WEXP + WMAN;
    localparam QFRAC_BASE = WMAN + 4;
    localparam QFRAC = QFRAC_BASE + (QFRAC_BASE % 2);
    localparam LATENCY = QFRAC + 4;

    localparam DEFAULT_WEXP = 6;
    localparam DEFAULT_WMAN = 18;
    localparam DEFAULT_WFULL = DEFAULT_WEXP + DEFAULT_WMAN;
    localparam DEFAULT_QFRAC_BASE = DEFAULT_WMAN + 4;
    localparam DEFAULT_QFRAC = DEFAULT_QFRAC_BASE + (DEFAULT_QFRAC_BASE % 2);
    localparam DEFAULT_LATENCY = DEFAULT_QFRAC + 4;

    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg [WFULL-1:0] a = 0;
    reg [WFULL-1:0] b = 0;

    wire out_valid;
    wire [WFULL-1:0] q;
    wire div0;

    reg default_in_valid = 1'b0;
    reg [DEFAULT_WFULL-1:0] default_a = 0;
    reg [DEFAULT_WFULL-1:0] default_b = 0;

    wire default_out_valid;
    wire [DEFAULT_WFULL-1:0] default_q;
    wire default_div0;

    reg expected_valid_pipe [0:LATENCY-1];
    reg [WFULL-1:0] expected_q_pipe [0:LATENCY-1];
    reg expected_div0_pipe [0:LATENCY-1];
    reg default_expected_valid_pipe [0:DEFAULT_LATENCY-1];
    reg [DEFAULT_WFULL-1:0] default_expected_q_pipe [0:DEFAULT_LATENCY-1];
    reg default_expected_div0_pipe [0:DEFAULT_LATENCY-1];

    integer pipe_i;
    integer flush_i;
    integer reset_i;
    integer cases_checked = 0;
    integer outputs_checked = 0;
    integer default_cases_checked = 0;
    integer default_outputs_checked = 0;

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

    zkf_div default_dut (
        .clk(clk),
        .rst(rst),
        .in_valid(default_in_valid),
        .a(default_a),
        .b(default_b),
        .out_valid(default_out_valid),
        .q(default_q),
        .div0(default_div0)
    );

    task automatic clear_model;
        begin
            for (pipe_i = 0; pipe_i < LATENCY; pipe_i = pipe_i + 1) begin
                expected_valid_pipe[pipe_i] = 1'b0;
                expected_q_pipe[pipe_i] = 0;
                expected_div0_pipe[pipe_i] = 1'b0;
            end
            for (pipe_i = 0; pipe_i < DEFAULT_LATENCY; pipe_i = pipe_i + 1) begin
                default_expected_valid_pipe[pipe_i] = 1'b0;
                default_expected_q_pipe[pipe_i] = 0;
                default_expected_div0_pipe[pipe_i] = 1'b0;
            end
        end
    endtask

    task automatic tick;
        input expected_valid_in;
        input [WFULL-1:0] expected_q_in;
        input expected_div0_in;
        input default_expected_valid_in;
        input [DEFAULT_WFULL-1:0] default_expected_q_in;
        input default_expected_div0_in;
        begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === expected_valid_pipe[LATENCY-1]);
            if (expected_valid_pipe[LATENCY-1]) begin
                `REQUIRE(q === expected_q_pipe[LATENCY-1]);
                `REQUIRE(div0 === expected_div0_pipe[LATENCY-1]);
                outputs_checked = outputs_checked + 1;
            end

            `REQUIRE(default_out_valid === default_expected_valid_pipe[DEFAULT_LATENCY-1]);
            if (default_expected_valid_pipe[DEFAULT_LATENCY-1]) begin
                `REQUIRE(default_q === default_expected_q_pipe[DEFAULT_LATENCY-1]);
                `REQUIRE(default_div0 === default_expected_div0_pipe[DEFAULT_LATENCY-1]);
                default_outputs_checked = default_outputs_checked + 1;
            end

            for (pipe_i = LATENCY - 1; pipe_i > 0; pipe_i = pipe_i - 1) begin
                expected_valid_pipe[pipe_i] = expected_valid_pipe[pipe_i-1];
                expected_q_pipe[pipe_i] = expected_q_pipe[pipe_i-1];
                expected_div0_pipe[pipe_i] = expected_div0_pipe[pipe_i-1];
            end
            expected_valid_pipe[0] = expected_valid_in;
            expected_q_pipe[0] = expected_q_in;
            expected_div0_pipe[0] = expected_div0_in;

            for (pipe_i = DEFAULT_LATENCY - 1; pipe_i > 0; pipe_i = pipe_i - 1) begin
                default_expected_valid_pipe[pipe_i] = default_expected_valid_pipe[pipe_i-1];
                default_expected_q_pipe[pipe_i] = default_expected_q_pipe[pipe_i-1];
                default_expected_div0_pipe[pipe_i] = default_expected_div0_pipe[pipe_i-1];
            end
            default_expected_valid_pipe[0] = default_expected_valid_in;
            default_expected_q_pipe[0] = default_expected_q_in;
            default_expected_div0_pipe[0] = default_expected_div0_in;
        end
    endtask

    task automatic drive_case;
        input integer case_id;
        input [WFULL-1:0] a_value;
        input [WFULL-1:0] b_value;
        input [WFULL-1:0] expected_q_value;
        input expected_div0_value;
        begin
            `REQUIRE(case_id == cases_checked);
            in_valid = 1'b1;
            a = a_value;
            b = b_value;
            default_in_valid = 1'b0;
            default_a = 0;
            default_b = 0;
            tick(1'b1, expected_q_value, expected_div0_value, 1'b0, 0, 1'b0);
            cases_checked = cases_checked + 1;
        end
    endtask

    task automatic drive_invalid;
        begin
            in_valid = 1'b0;
            a = 32'hffffffff;
            b = 32'h805a5a5a;
            default_in_valid = 1'b0;
            default_a = 0;
            default_b = 0;
            tick(1'b0, 0, 1'b0, 1'b0, 0, 1'b0);
        end
    endtask

    task automatic drive_default_case;
        input [DEFAULT_WFULL-1:0] a_value;
        input [DEFAULT_WFULL-1:0] b_value;
        input [DEFAULT_WFULL-1:0] expected_q_value;
        input expected_div0_value;
        begin
            in_valid = 1'b0;
            a = 0;
            b = 0;
            default_in_valid = 1'b1;
            default_a = a_value;
            default_b = b_value;
            tick(1'b0, 0, 1'b0, 1'b1, expected_q_value, expected_div0_value);
            default_cases_checked = default_cases_checked + 1;
        end
    endtask

    task automatic drive_reset_cycle;
        begin
            rst = 1'b1;
            in_valid = 1'b1;
            a = 32'h3f800000;
            b = 32'h00000000;
            default_in_valid = 1'b1;
            default_a = 24'h3e0000;
            default_b = 24'h000000;
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === 1'b0);
            `REQUIRE(default_out_valid === 1'b0);
            clear_model();
        end
    endtask

    initial begin
        clear_model();

        in_valid = 1'b1;
        a = 32'hffffffff;
        b = 32'h00000000;
        default_in_valid = 1'b1;
        default_a = {DEFAULT_WFULL{1'b1}};
        default_b = 0;
        for (reset_i = 0; reset_i < LATENCY + 2; reset_i = reset_i + 1) begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === 1'b0);
            `REQUIRE(default_out_valid === 1'b0);
        end

        rst = 1'b0;
        clear_model();

        drive_case(0,  32'h00000000, 32'h3f800000, 32'h00000000, 1'b0);
        drive_case(1,  32'h805a5a5a, 32'h7f800000, 32'h00000000, 1'b0);
        drive_case(2,  32'h00000000, 32'h00000000, 32'h00000000, 1'b1);
        drive_case(3,  32'h3f800000, 32'h00000000, 32'h7f800000, 1'b1);
        drive_case(4,  32'hbf800000, 32'h00000000, 32'hff800000, 1'b1);
        drive_case(5,  32'h3f800000, 32'h805a5a5a, 32'h7f800000, 1'b1);

        drive_invalid();

        drive_case(6,  32'h3f800000, 32'h3f800000, 32'h3f800000, 1'b0);
        drive_case(7,  32'hbf800000, 32'h3f800000, 32'hbf800000, 1'b0);
        drive_case(8,  32'h3f800000, 32'hbf800000, 32'hbf800000, 1'b0);
        drive_case(9,  32'hbf800000, 32'hbf800000, 32'h3f800000, 1'b0);
        drive_case(10, 32'h3fc00000, 32'h40000000, 32'h3f400000, 1'b0);
        drive_case(11, 32'h3fa00000, 32'h3fc00000, 32'h3f555555, 1'b0);
        drive_case(12, 32'h3fc00000, 32'h3fc00000, 32'h3f800000, 1'b0);

        drive_invalid();
        drive_invalid();

        drive_case(13, 32'h3f800000, 32'h7f800000, 32'h00000000, 1'b0);
        drive_case(14, 32'hbf800000, 32'h7f800000, 32'h00000000, 1'b0);
        drive_case(15, 32'h40000000, 32'hff800000, 32'h00000000, 1'b0);
        drive_case(16, 32'h7f800000, 32'h3f800000, 32'h7f800000, 1'b0);
        drive_case(17, 32'hff800000, 32'h3f800000, 32'hff800000, 1'b0);
        drive_case(18, 32'h7f812345, 32'hbf800000, 32'hff800000, 1'b0);
        drive_case(19, 32'h7f800000, 32'h7f800000, 32'h00000000, 1'b0);
        drive_case(20, 32'hff800000, 32'h7f800000, 32'h00000000, 1'b0);
        drive_case(21, 32'hffffffff, 32'h7f812345, 32'h00000000, 1'b0);

        drive_case(22, 32'h00800000, 32'h40000000, 32'h00000000, 1'b0);
        drive_case(23, 32'h00800000, 32'h3f800000, 32'h00800000, 1'b0);
        drive_case(24, 32'h80800000, 32'h3f800000, 32'h80800000, 1'b0);
        drive_case(25, 32'h7f7fffff, 32'h3f800000, 32'h7f7fffff, 1'b0);
        drive_case(26, 32'hff7fffff, 32'h3f800000, 32'hff7fffff, 1'b0);
        drive_case(27, 32'h7f7fffff, 32'h3f000000, 32'h7f800000, 1'b0);
        drive_case(28, 32'hff7fffff, 32'h3f000000, 32'hff800000, 1'b0);

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            drive_invalid();
        end

        drive_reset_cycle();
        drive_reset_cycle();
        rst = 1'b0;
        clear_model();

        drive_case(29, 32'h40400000, 32'h40000000, 32'h3fc00000, 1'b0);
        drive_case(30, 32'h3f800002, 32'h3fa00000, 32'h3f4cccd0, 1'b0);
        drive_case(31, 32'h3f800001, 32'h3fc00000, 32'h3f2aaaac, 1'b0);
        drive_case(32, 32'h3f800001, 32'h3fa00000, 32'h3f4cccce, 1'b0);
        drive_case(33, 32'h3f800001, 32'h3fe00000, 32'h3f124926, 1'b0);

        drive_default_case(24'h3e0000, 24'h3e0000, 24'h3e0000, 1'b0);

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            drive_invalid();
        end

        `REQUIRE(cases_checked == 34);
        `REQUIRE(outputs_checked == cases_checked);
        `REQUIRE(default_cases_checked == 1);
        `REQUIRE(default_outputs_checked == default_cases_checked);
        $display("checked %0d manual divider cases and %0d default-parameter smoke case",
                 cases_checked, default_cases_checked);
        $finish;
    end
endmodule

`default_nettype wire
