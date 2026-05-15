// iverilog -Wall -Wno-timescale -y../hdl zkf_div_random_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module zkf_div_random_tb;
    localparam WEXP = 8;
    localparam WMAN = 24;
    localparam WFULL = WEXP + WMAN;
    localparam QFRAC_BASE = WMAN + 2;
    localparam QFRAC = QFRAC_BASE + (QFRAC_BASE % 2);
    localparam LATENCY = (QFRAC / 2) + 3;
    localparam VECTOR_COUNT = 20000;
    localparam VECTOR_WIDTH = (3 * WFULL) + 1;

    localparam DIV0_LSB = 0;
    localparam Q_LSB = DIV0_LSB + 1;
    localparam B_LSB = Q_LSB + WFULL;
    localparam A_LSB = B_LSB + WFULL;

    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg [WFULL-1:0] a = 0;
    reg [WFULL-1:0] b = 0;

    wire out_valid;
    wire [WFULL-1:0] q;
    wire div0;

    reg [VECTOR_WIDTH-1:0] vectors [0:VECTOR_COUNT-1];
    reg expected_valid_pipe [0:LATENCY-1];
    reg [WFULL-1:0] expected_q_pipe [0:LATENCY-1];
    reg expected_div0_pipe [0:LATENCY-1];

    integer vector_i;
    integer pipe_i;
    integer flush_i;
    integer outputs_checked = 0;
    reg [VECTOR_WIDTH-1:0] vector_word;

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

    task automatic drive_vector;
        input [VECTOR_WIDTH-1:0] v;
        begin
            `REQUIRE(^v !== 1'bx);
            in_valid = 1'b1;
            a = v[A_LSB+WFULL-1:A_LSB];
            b = v[B_LSB+WFULL-1:B_LSB];
            tick(1'b1, v[Q_LSB+WFULL-1:Q_LSB], v[DIV0_LSB]);
        end
    endtask

    initial begin
        $readmemh("div_random_vectors.memh", vectors);
        clear_model();

        repeat (LATENCY + 2) begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === 1'b0);
        end

        rst = 1'b0;
        clear_model();

        for (vector_i = 0; vector_i < VECTOR_COUNT; vector_i = vector_i + 1) begin
            vector_word = vectors[vector_i];
            drive_vector(vector_word);
        end

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            in_valid = 1'b0;
            a = 0;
            b = 0;
            tick(1'b0, 0, 1'b0);
        end

        `REQUIRE(outputs_checked == VECTOR_COUNT);
        $display("checked %0d deterministic large-format divider vectors", outputs_checked);
        $finish;
    end
endmodule

`default_nettype wire
