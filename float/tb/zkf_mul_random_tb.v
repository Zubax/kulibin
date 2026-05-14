// iverilog -Wall -Wno-timescale -y../hdl zkf_mul_random_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module zkf_mul_random_tb;
    localparam WEXP = 8;
    localparam WMAN = 24;
    localparam WFULL = WEXP + WMAN;
    localparam LATENCY = 4;
    localparam VECTOR_COUNT = 20000;
    localparam VECTOR_WIDTH = 3 * WFULL;

    localparam Y_LSB = 0;
    localparam B_LSB = Y_LSB + WFULL;
    localparam A_LSB = B_LSB + WFULL;

    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg [WFULL-1:0] a = 0;
    reg [WFULL-1:0] b = 0;

    wire out_valid;
    wire [WFULL-1:0] y;
    wire saturated;

    reg [VECTOR_WIDTH-1:0] vectors [0:VECTOR_COUNT-1];
    reg expected_valid_pipe [0:LATENCY-1];
    reg [WFULL-1:0] expected_y_pipe [0:LATENCY-1];

    integer vector_i;
    integer pipe_i;
    integer flush_i;
    integer outputs_checked = 0;
    reg [VECTOR_WIDTH-1:0] vector_word;

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

    task automatic drive_vector;
        input [VECTOR_WIDTH-1:0] v;
        begin
            `REQUIRE(^v !== 1'bx);
            in_valid = 1'b1;
            a = v[A_LSB+WFULL-1:A_LSB];
            b = v[B_LSB+WFULL-1:B_LSB];
            tick(1'b1, v[Y_LSB+WFULL-1:Y_LSB]);
        end
    endtask

    initial begin
        $readmemh("mul_random_vectors.memh", vectors);
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
            tick(1'b0, 0);
        end

        `REQUIRE(outputs_checked == VECTOR_COUNT);
        $display("checked %0d deterministic large-format multiplier vectors", outputs_checked);
        $finish;
    end
endmodule

`default_nettype wire
