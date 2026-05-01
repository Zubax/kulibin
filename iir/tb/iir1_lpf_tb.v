// iverilog -Wall -Wno-timescale -y. iir1_lpf_tb.v && vvp a.out

`ifndef REQUIRE
`define REQUIRE(cond) if (!(cond)) $fatal
`endif

`default_nettype none
`timescale 100ns / 100ns

module iir1_lpf_tb#(
    parameter FINISH = 1
)(
    output reg done
);
    reg clk = 1'b0;
    always #1 clk = ~clk;

    reg rst = 1'b1;

    // Main LPF instance. With WIN=8, K=2, WOUT defaults to 10, so outputs are scaled by 4.
    reg                 step_valid = 1'b0;
    reg signed [7:0]    step_in = 8'sd0;
    wire                step_ready;
    wire                step_out_valid;
    wire signed [9:0]   step_out;
    iir1_lpf#(
        .WIN(8),
        .K(2)
    ) step_lpf (
        .clk(clk),
        .rst(rst),
        .in_ready(step_ready),
        .in_valid(step_valid),
        .in(step_in),
        .out_valid(step_out_valid),
        .out(step_out)
    );

    // K=0 degenerates to a pass-through with the same pipeline/handshake contract.
    reg                 pass_valid = 1'b0;
    reg signed [7:0]    pass_in = 8'sd0;
    wire                pass_ready;
    wire                pass_out_valid;
    wire signed [7:0]   pass_out;
    iir1_lpf#(
        .WIN(8),
        .K(0)
    ) pass_lpf (
        .clk(clk),
        .rst(rst),
        .in_ready(pass_ready),
        .in_valid(pass_valid),
        .in(pass_in),
        .out_valid(pass_out_valid),
        .out(pass_out)
    );

    // Explicitly narrowed output. The internal state is still wide; only the public result is rounded.
    reg                 narrow_valid = 1'b0;
    reg signed [7:0]    narrow_in = 8'sd0;
    wire                narrow_ready;
    wire                narrow_out_valid;
    wire signed [7:0]   narrow_out;
    iir1_lpf#(
        .WIN(8),
        .K(4),
        .WOUT(8)
    ) narrow_lpf (
        .clk(clk),
        .rst(rst),
        .in_ready(narrow_ready),
        .in_valid(narrow_valid),
        .in(narrow_in),
        .out_valid(narrow_out_valid),
        .out(narrow_out)
    );

    reg signed [9:0] step_out_prev;
    reg signed [7:0] pass_out_prev;
    reg signed [7:0] narrow_out_prev;
    always @(posedge clk) begin
        if (rst) begin
            step_out_prev   <= 10'sd0;
            pass_out_prev   <= 8'sd0;
            narrow_out_prev <= 8'sd0;
        end else begin
            if (!step_out_valid) begin
                `REQUIRE(step_out === step_out_prev);
            end
            if (!pass_out_valid) begin
                `REQUIRE(pass_out === pass_out_prev);
            end
            if (!narrow_out_valid) begin
                `REQUIRE(narrow_out === narrow_out_prev);
            end
            step_out_prev   <= step_out;
            pass_out_prev   <= pass_out;
            narrow_out_prev <= narrow_out;
        end
    end

    task automatic accept_step;
        input signed [7:0] value;
        begin
            while (!step_ready) begin
                @(negedge clk);
            end
            step_in = value;
            step_valid = 1'b1;
            @(negedge clk);
            step_valid = 1'b0;
        end
    endtask

    task automatic wait_step_out;
        integer wait_count;
        begin
            for (wait_count = 0; (wait_count < 20) && !step_out_valid; wait_count = wait_count + 1) begin
                @(negedge clk);
            end
            `REQUIRE(step_out_valid);
        end
    endtask

    task automatic accept_pass;
        input signed [7:0] value;
        begin
            while (!pass_ready) begin
                @(negedge clk);
            end
            pass_in = value;
            pass_valid = 1'b1;
            @(negedge clk);
            pass_valid = 1'b0;
        end
    endtask

    task automatic wait_pass_out;
        integer wait_count;
        begin
            for (wait_count = 0; (wait_count < 20) && !pass_out_valid; wait_count = wait_count + 1) begin
                @(negedge clk);
            end
            `REQUIRE(pass_out_valid);
        end
    endtask

    task automatic accept_narrow;
        input signed [7:0] value;
        begin
            while (!narrow_ready) begin
                @(negedge clk);
            end
            narrow_in = value;
            narrow_valid = 1'b1;
            @(negedge clk);
            narrow_valid = 1'b0;
        end
    endtask

    task automatic wait_narrow_out;
        integer wait_count;
        begin
            for (wait_count = 0; (wait_count < 30) && !narrow_out_valid; wait_count = wait_count + 1) begin
                @(negedge clk);
            end
            `REQUIRE(narrow_out_valid);
        end
    endtask

    integer idx;
    initial begin
        done = 1'b0;
        if (FINISH) begin
            $dumpfile("iir1_lpf_tb.vcd");
            $dumpvars();
        end

        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);

        `REQUIRE(step_ready);
        accept_step(8'sd64);
        // Present another value while the LPF is busy; it must not be accepted.
        `REQUIRE(!step_ready);
        step_in = -8'sd64;
        step_valid = 1'b1;
        @(negedge clk);
        step_valid = 1'b0;
        wait_step_out();
        `REQUIRE(step_out === 10'sd64);

        accept_step(8'sd64);
        wait_step_out();
        `REQUIRE(step_out === 10'sd112);

        accept_step(8'sd64);
        wait_step_out();
        `REQUIRE(step_out === 10'sd148);

        for (idx = 0; idx < 96; idx = idx + 1) begin
            accept_step(8'sd64);
            wait_step_out();
        end
        `REQUIRE(step_out === 10'sd256);

        for (idx = 0; idx < 128; idx = idx + 1) begin
            accept_step(-8'sd10);
            wait_step_out();
        end
        `REQUIRE(step_out === -10'sd40);

        accept_pass(8'sd37);
        wait_pass_out();
        `REQUIRE(pass_out === 8'sd37);

        accept_pass(-8'sd12);
        wait_pass_out();
        `REQUIRE(pass_out === -8'sd12);

        for (idx = 0; idx < 256; idx = idx + 1) begin
            accept_narrow(8'sd23);
            wait_narrow_out();
        end
        `REQUIRE(narrow_out === 8'sd23);

        for (idx = 0; idx < 256; idx = idx + 1) begin
            accept_narrow(-8'sd23);
            wait_narrow_out();
        end
        `REQUIRE(narrow_out === -8'sd23);

        done = 1'b1;
        if (FINISH) begin
            $finish;
        end
    end
endmodule
