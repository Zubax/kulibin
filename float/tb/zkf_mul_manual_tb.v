// iverilog -Wall -Wno-timescale -y../hdl zkf_mul_manual_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module zkf_mul_manual_tb;
    localparam WEXP = 8;
    localparam WMAN = 24;
    localparam WFULL = WEXP + WMAN;
    localparam LATENCY = 3;

    localparam DEFAULT_WEXP = 6;
    localparam DEFAULT_WMAN = 18;
    localparam DEFAULT_WFULL = DEFAULT_WEXP + DEFAULT_WMAN;

    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg [WFULL-1:0] a = 0;
    reg [WFULL-1:0] b = 0;

    wire out_valid;
    wire [WFULL-1:0] y;

    reg default_in_valid = 1'b0;
    reg [DEFAULT_WFULL-1:0] default_a = 0;
    reg [DEFAULT_WFULL-1:0] default_b = 0;

    wire default_out_valid;
    wire [DEFAULT_WFULL-1:0] default_y;

    reg expected_valid_pipe [0:LATENCY-1];
    reg [WFULL-1:0] expected_y_pipe [0:LATENCY-1];
    reg default_expected_valid_pipe [0:LATENCY-1];
    reg [DEFAULT_WFULL-1:0] default_expected_y_pipe [0:LATENCY-1];

    integer pipe_i;
    integer flush_i;
    integer reset_i;
    integer cases_checked = 0;
    integer outputs_checked = 0;
    integer default_cases_checked = 0;
    integer default_outputs_checked = 0;

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
        .y(y)
    );

    zkf_mul default_dut (
        .clk(clk),
        .rst(rst),
        .in_valid(default_in_valid),
        .a(default_a),
        .b(default_b),
        .out_valid(default_out_valid),
        .y(default_y)
    );

    task automatic clear_model;
        begin
            for (pipe_i = 0; pipe_i < LATENCY; pipe_i = pipe_i + 1) begin
                expected_valid_pipe[pipe_i] = 1'b0;
                expected_y_pipe[pipe_i] = 0;
                default_expected_valid_pipe[pipe_i] = 1'b0;
                default_expected_y_pipe[pipe_i] = 0;
            end
        end
    endtask

    task automatic tick;
        input expected_valid_in;
        input [WFULL-1:0] expected_y_in;
        input default_expected_valid_in;
        input [DEFAULT_WFULL-1:0] default_expected_y_in;
        begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === expected_valid_pipe[LATENCY-1]);
            if (expected_valid_pipe[LATENCY-1]) begin
                `REQUIRE(y === expected_y_pipe[LATENCY-1]);
                outputs_checked = outputs_checked + 1;
            end

            `REQUIRE(default_out_valid === default_expected_valid_pipe[LATENCY-1]);
            if (default_expected_valid_pipe[LATENCY-1]) begin
                `REQUIRE(default_y === default_expected_y_pipe[LATENCY-1]);
                default_outputs_checked = default_outputs_checked + 1;
            end

            for (pipe_i = LATENCY - 1; pipe_i > 0; pipe_i = pipe_i - 1) begin
                expected_valid_pipe[pipe_i] = expected_valid_pipe[pipe_i-1];
                expected_y_pipe[pipe_i] = expected_y_pipe[pipe_i-1];
                default_expected_valid_pipe[pipe_i] = default_expected_valid_pipe[pipe_i-1];
                default_expected_y_pipe[pipe_i] = default_expected_y_pipe[pipe_i-1];
            end
            expected_valid_pipe[0] = expected_valid_in;
            expected_y_pipe[0] = expected_y_in;
            default_expected_valid_pipe[0] = default_expected_valid_in;
            default_expected_y_pipe[0] = default_expected_y_in;
        end
    endtask

    task automatic drive_case;
        input integer case_id;
        input [WFULL-1:0] a_value;
        input [WFULL-1:0] b_value;
        input [WFULL-1:0] expected_y_value;
        begin
            `REQUIRE(case_id == cases_checked);
            in_valid = 1'b1;
            a = a_value;
            b = b_value;
            default_in_valid = 1'b0;
            default_a = 0;
            default_b = 0;
            tick(1'b1, expected_y_value, 1'b0, 0);
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
            tick(1'b0, 0, 1'b0, 0);
        end
    endtask

    task automatic drive_default_case;
        input [DEFAULT_WFULL-1:0] a_value;
        input [DEFAULT_WFULL-1:0] b_value;
        input [DEFAULT_WFULL-1:0] expected_y_value;
        begin
            in_valid = 1'b0;
            a = 0;
            b = 0;
            default_in_valid = 1'b1;
            default_a = a_value;
            default_b = b_value;
            tick(1'b0, 0, 1'b1, expected_y_value);
            default_cases_checked = default_cases_checked + 1;
        end
    endtask

    task automatic drive_reset_cycle;
        begin
            rst = 1'b1;
            in_valid = 1'b1;
            a = 32'h3f800000;
            b = 32'h7fffffff;
            default_in_valid = 1'b1;
            default_a = 24'h3e0000;
            default_b = 24'h3e0000;
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
        b = 32'hffffffff;
        default_in_valid = 1'b1;
        default_a = {DEFAULT_WFULL{1'b1}};
        default_b = {DEFAULT_WFULL{1'b1}};
        for (reset_i = 0; reset_i < LATENCY + 2; reset_i = reset_i + 1) begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === 1'b0);
            `REQUIRE(default_out_valid === 1'b0);
        end

        rst = 1'b0;
        clear_model();

        drive_case(0,  32'h00000000, 32'h3f800000, 32'h00000000);  // canonical zero
        drive_case(1,  32'h805a5a5a, 32'h7fffffff, 32'h00000000);  // zero payload beats infinity
        drive_case(2,  32'hbf800000, 32'h007fffff, 32'h00000000);  // zero exponent ignored

        drive_invalid();

        drive_case(3,  32'h3f800000, 32'h3f800000, 32'h3f800000);  // +1 * +1
        drive_case(4,  32'hbf800000, 32'h3f800000, 32'hbf800000);  // -1 * +1
        drive_case(5,  32'hbf800000, 32'hbf800000, 32'h3f800000);  // -1 * -1
        drive_case(6,  32'h3fc00000, 32'h40000000, 32'h40400000);  // 1.5 * 2.0
        drive_case(7,  32'h3fa00000, 32'h3fc00000, 32'h3ff00000);  // 1.25 * 1.5
        drive_case(8,  32'h3fc00000, 32'h3fc00000, 32'h40100000);  // normalization carry

        drive_invalid();
        drive_invalid();

        drive_case(9,  32'h7f800000, 32'h3f800000, 32'h7f800000);  // canonical +infinity
        drive_case(10, 32'h7fffffff, 32'h3f800000, 32'h7f800000);  // noncanonical +infinity
        drive_case(11, 32'hffabcdef, 32'h3f800000, 32'hff800000);  // noncanonical -infinity
        drive_case(12, 32'h3f800000, 32'h7f800000, 32'h7f800000);  // finite nonzero * +infinity
        drive_case(13, 32'hbf800000, 32'h7f800001, 32'hff800000);  // negative finite * +infinity
        drive_case(14, 32'h40000000, 32'hff800001, 32'hff800000);  // finite nonzero * -infinity
        drive_case(15, 32'h00000000, 32'h7f800000, 32'h00000000);  // zero * infinity
        drive_case(16, 32'h805a5a5a, 32'hffabcdef, 32'h00000000);  // noncanonical zero * infinity
        drive_case(17, 32'h7f800000, 32'h7fffffff, 32'h7f800000);  // +infinity * +infinity
        drive_case(18, 32'hff800000, 32'h7f800001, 32'hff800000);  // -infinity * +infinity
        drive_case(19, 32'hffffffff, 32'hffabcdef, 32'h7f800000);  // -infinity * -infinity

        drive_case(20, 32'h00800000, 32'h3f000000, 32'h00000000);  // underflow flush
        drive_case(21, 32'h00800000, 32'h3f800000, 32'h00800000);  // minimum normal
        drive_case(22, 32'h80800000, 32'h3f800000, 32'h80800000);  // negative minimum normal
        drive_case(23, 32'h7f7fffff, 32'h3f800000, 32'h7f7fffff);  // maximum finite
        drive_case(24, 32'hff7fffff, 32'h3f800000, 32'hff7fffff);  // negative maximum finite
        drive_case(25, 32'h7f7fffff, 32'h40000000, 32'h7f800000);  // positive overflow to infinity
        drive_case(26, 32'hff7fffff, 32'h40000000, 32'hff800000);  // negative overflow to infinity

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            drive_invalid();
        end

        drive_reset_cycle();
        drive_reset_cycle();
        rst = 1'b0;
        clear_model();

        drive_case(27, 32'h3f800002, 32'h3fa00000, 32'h3fa00002);  // tie, retained even
        drive_case(28, 32'h3f800001, 32'h3fc00000, 32'h3fc00002);  // tie, retained odd
        drive_case(29, 32'h3f800001, 32'h3fa00000, 32'h3fa00001);  // round down
        drive_case(30, 32'h3f800001, 32'h3fe00000, 32'h3fe00002);  // round up

        drive_default_case(24'h3e0000, 24'h3e0000, 24'h3e0000);    // default WEXP=6, WMAN=18

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            drive_invalid();
        end

        `REQUIRE(cases_checked == 31);
        `REQUIRE(outputs_checked == cases_checked);
        `REQUIRE(default_cases_checked == 1);
        `REQUIRE(default_outputs_checked == default_cases_checked);
        $display("checked %0d manual multiplier cases and %0d default-parameter smoke case",
                 cases_checked, default_cases_checked);
        $finish;
    end
endmodule

`default_nettype wire
