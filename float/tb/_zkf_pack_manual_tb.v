// iverilog -Wall -Wno-timescale -y../hdl _zkf_pack_manual_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module _zkf_pack_manual_tb;
    localparam WEXP = 5;
    localparam WMAN = 8;
    localparam WMAG = 16;
    localparam WSCALE = 6;
    localparam WFULL = WEXP + WMAN;
    localparam LATENCY = 1;

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

    integer pipe_i;
    integer flush_i;
    integer cases_checked = 0;
    integer outputs_checked = 0;

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

    task automatic drive_case;
        input integer case_id;
        input sign_value;
        input [WMAG-1:0] mag_value;
        input signed [WSCALE-1:0] scale_value;
        input [WFULL-1:0] expected_y_value;
        begin
            `REQUIRE(case_id == cases_checked);
            in_valid = 1'b1;
            sign = sign_value;
            mag = mag_value;
            scale = scale_value;
            tick(1'b1, expected_y_value);
            cases_checked = cases_checked + 1;
        end
    endtask

    task automatic drive_invalid;
        begin
            in_valid = 1'b0;
            sign = 1'b1;
            mag = {WMAG{1'b1}};
            scale = -1;
            tick(1'b0, 0);
        end
    endtask

    initial begin
        clear_model();

        in_valid = 1'b1;
        sign = 1'b1;
        mag = {WMAG{1'b1}};
        scale = 6'sd31;
        repeat (3) begin
            @(posedge clk);
            #1;
            `REQUIRE(out_valid === 1'b0);
        end

        rst = 1'b0;
        clear_model();

        drive_case(0,  1'b1, 16'd0,      6'sd31,  13'h0000);  // zero is canonical positive
        drive_case(1,  1'b0, 16'd1,      -15,     13'h0000);  // below min normal flushes
        drive_case(2,  1'b0, 16'd255,    -22,     13'h0000);  // one below min, no round carry
        drive_case(3,  1'b0, 16'd511,    -23,     13'h0080);  // one below min, round-carry to min normal
        drive_case(4,  1'b1, 16'd511,    -23,     13'h1080);  // negative round-carry to min normal
        drive_case(5,  1'b0, 16'd1,      -14,     13'h0080);  // minimum normal
        drive_case(6,  1'b1, 16'd1,      -14,     13'h1080);  // negative minimum normal

        drive_invalid();

        drive_case(7,  1'b0, 16'd1,      6'sd0,   13'h0780);  // +1.0
        drive_case(8,  1'b1, 16'd1,      6'sd0,   13'h1780);  // -1.0
        drive_case(9,  1'b0, 16'd3,      -1,      13'h07c0);  // +1.5
        drive_case(10, 1'b0, 16'd1,      6'sd1,   13'h0800);  // +2.0
        drive_case(11, 1'b1, 16'd1,      6'sd1,   13'h1800);  // -2.0
        drive_case(12, 1'b0, 16'd255,    -7,      13'h07ff);  // max significand at exponent 0

        drive_invalid();
        drive_invalid();

        drive_case(13, 1'b0, 16'd513,    -9,      13'h0780);  // round down
        drive_case(14, 1'b0, 16'd514,    -9,      13'h0780);  // tie to even, lower even
        drive_case(15, 1'b0, 16'd515,    -9,      13'h0781);  // round up
        drive_case(16, 1'b0, 16'd518,    -9,      13'h0782);  // tie to even, upper even
        drive_case(17, 1'b0, 16'd1021,   -9,      13'h07ff);  // just below carry threshold
        drive_case(18, 1'b0, 16'd511,    -8,      13'h0800);  // tie carry to +2.0
        drive_case(19, 1'b1, 16'd511,    -8,      13'h1800);  // negative tie carry to -2.0

        drive_case(20, 1'b0, 16'h8000,   6'sd0,   13'h0f00);  // high input bit exact
        drive_case(21, 1'b0, 16'hffff,   6'sd0,   13'h0f80);  // round-carry to +infinity
        drive_case(22, 1'b0, 16'd255,    6'sd8,   13'h0f7f);  // maximum finite
        drive_case(23, 1'b0, 16'd1021,   6'sd6,   13'h0f7f);  // above max, rounds to max
        drive_case(24, 1'b0, 16'd511,    6'sd7,   13'h0f80);  // round-to-infinity tie
        drive_case(25, 1'b1, 16'd511,    6'sd7,   13'h1f80);  // negative round-to-infinity tie
        drive_case(26, 1'b0, 16'd1,      6'sd16,  13'h0f80);  // exponent overflow

        for (flush_i = 0; flush_i < LATENCY + 2; flush_i = flush_i + 1) begin
            drive_invalid();
        end

        `REQUIRE(cases_checked == 27);
        `REQUIRE(outputs_checked == cases_checked);
        $display("checked %0d manual golden pack cases", cases_checked);
        $finish;
    end
endmodule

`default_nettype wire
