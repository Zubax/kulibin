// iverilog -Wall -Wno-timescale -y../hdl zkf_div_extensive_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module zkf_div_extensive_tb;
    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;

    wire done_w3_m5;
    wire done_w4_m6;
    wire done_w5_m11;
    wire done_w6_m18;
    wire done_w7_m17;
    wire done_w8_m24;
    wire done_w11_m53;

    zkf_div_extensive_case #(
        .WEXP(3),
        .WMAN(5),
        .VECTOR_COUNT(4096),
        .MEM_FILE("div_ext_w3_m5.memh")
    ) u_w3_m5 (
        .clk(clk),
        .rst(rst),
        .done(done_w3_m5)
    );

    zkf_div_extensive_case #(
        .WEXP(4),
        .WMAN(6),
        .VECTOR_COUNT(4096),
        .MEM_FILE("div_ext_w4_m6.memh")
    ) u_w4_m6 (
        .clk(clk),
        .rst(rst),
        .done(done_w4_m6)
    );

    zkf_div_extensive_case #(
        .WEXP(5),
        .WMAN(11),
        .VECTOR_COUNT(8192),
        .MEM_FILE("div_ext_w5_m11.memh")
    ) u_w5_m11 (
        .clk(clk),
        .rst(rst),
        .done(done_w5_m11)
    );

    zkf_div_extensive_case #(
        .WEXP(6),
        .WMAN(18),
        .VECTOR_COUNT(8192),
        .MEM_FILE("div_ext_w6_m18.memh")
    ) u_w6_m18 (
        .clk(clk),
        .rst(rst),
        .done(done_w6_m18)
    );

    zkf_div_extensive_case #(
        .WEXP(7),
        .WMAN(17),
        .VECTOR_COUNT(8192),
        .MEM_FILE("div_ext_w7_m17.memh")
    ) u_w7_m17 (
        .clk(clk),
        .rst(rst),
        .done(done_w7_m17)
    );

    zkf_div_extensive_case #(
        .WEXP(8),
        .WMAN(24),
        .VECTOR_COUNT(20000),
        .MEM_FILE("div_ext_w8_m24.memh")
    ) u_w8_m24 (
        .clk(clk),
        .rst(rst),
        .done(done_w8_m24)
    );

    zkf_div_extensive_case #(
        .WEXP(11),
        .WMAN(53),
        .VECTOR_COUNT(20000),
        .MEM_FILE("div_ext_w11_m53.memh")
    ) u_w11_m53 (
        .clk(clk),
        .rst(rst),
        .done(done_w11_m53)
    );

    initial begin
        repeat (8) begin
            @(posedge clk);
        end
        #1;
        rst = 1'b0;

        wait (
            done_w3_m5 &&
            done_w4_m6 &&
            done_w5_m11 &&
            done_w6_m18 &&
            done_w7_m17 &&
            done_w8_m24 &&
            done_w11_m53
        );

        @(posedge clk);
        $display("checked extensive divider vector sets");
        $finish;
    end
endmodule


module zkf_div_extensive_case #(
    parameter WEXP = 6,
    parameter WMAN = 18,
    parameter VECTOR_COUNT = 8192,
    parameter MEM_FILE = "div_ext_w6_m18.memh"
) (
    input wire clk,
    input wire rst,

    output reg done
);
    localparam WFULL = WEXP + WMAN;
    localparam QFRAC_BASE = WMAN + 2;
    localparam QFRAC = QFRAC_BASE + (QFRAC_BASE % 2);
    localparam LATENCY = (QFRAC / 2) + 3;
    localparam VECTOR_WIDTH = (3 * WFULL) + 1;

    localparam DIV0_LSB = 0;
    localparam Q_LSB = DIV0_LSB + 1;
    localparam B_LSB = Q_LSB + WFULL;
    localparam A_LSB = B_LSB + WFULL;

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
        done = 1'b0;
        $readmemh(MEM_FILE, vectors);
        clear_model();

        wait (rst === 1'b0);
        @(posedge clk);
        #1;
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
        $display("%m checked %0d divider vectors from %s", outputs_checked, MEM_FILE);
        done = 1'b1;
    end
endmodule

`default_nettype wire
