// iverilog -Wall -Wno-timescale -y. iir1_hpf_tb.v && vvp a.out

`ifndef REQUIRE
`define REQUIRE(cond) if (!(cond)) $fatal
`endif

`default_nettype none
`timescale 100ns / 100ns

module iir1_hpf_tb#(
    parameter FINISH = 1
)(
    output reg done
);
    reg clk = 1'b0;
    always #1 clk = ~clk;

    reg rst = 1'b1;

    // Main HPF instance. With WIN=8, K=2, WOUT defaults to 10, so outputs and bias are scaled by 4.
    reg                 step_valid = 1'b0;
    reg signed [7:0]    step_in = 8'sd0;
    wire                step_ready;
    wire                step_out_valid;
    wire signed [9:0]   step_out;
    wire signed [9:0]   step_bias;
    iir1_hpf#(
        .WIN(8),
        .K(2)
    ) step_hpf (
        .clk(clk),
        .rst(rst),
        .in_ready(step_ready),
        .in_valid(step_valid),
        .in(step_in),
        .out_valid(step_out_valid),
        .out(step_out),
        .bias(step_bias)
    );

    // Explicitly narrowed output. The diagnostic bias intentionally remains full WIN+K width.
    reg                 narrow_valid = 1'b0;
    reg signed [7:0]    narrow_in = 8'sd0;
    wire                narrow_ready;
    wire                narrow_out_valid;
    wire signed [7:0]   narrow_out;
    wire signed [11:0]  narrow_bias;
    iir1_hpf#(
        .WIN(8),
        .K(4),
        .WOUT(8)
    ) narrow_hpf (
        .clk(clk),
        .rst(rst),
        .in_ready(narrow_ready),
        .in_valid(narrow_valid),
        .in(narrow_in),
        .out_valid(narrow_out_valid),
        .out(narrow_out),
        .bias(narrow_bias)
    );

    // Fractional output for checking that sub-LSB bias residue is represented, not rounded away.
    reg                 frac_valid = 1'b0;
    reg signed [7:0]    frac_in = -8'sd10;
    wire                frac_ready;
    wire                frac_out_valid;
    wire signed [11:0]  frac_out;
    wire signed [11:0]  frac_bias;
    iir1_hpf#(
        .WIN(8),
        .K(4),
        .WOUT(12)
    ) frac_hpf (
        .clk(clk),
        .rst(rst),
        .in_ready(frac_ready),
        .in_valid(frac_valid),
        .in(frac_in),
        .out_valid(frac_out_valid),
        .out(frac_out),
        .bias(frac_bias)
    );

    // K=0 degenerates to complete DC tracking, so the high-pass output is zero for every accepted sample.
    reg                 pass_valid = 1'b0;
    reg signed [7:0]    pass_in = 8'sd0;
    wire                pass_ready;
    wire                pass_out_valid;
    wire signed [7:0]   pass_out;
    wire signed [7:0]   pass_bias;
    iir1_hpf#(
        .WIN(8),
        .K(0)
    ) pass_hpf (
        .clk(clk),
        .rst(rst),
        .in_ready(pass_ready),
        .in_valid(pass_valid),
        .in(pass_in),
        .out_valid(pass_out_valid),
        .out(pass_out),
        .bias(pass_bias)
    );

    reg signed [9:0]  step_out_prev;
    reg signed [7:0]  narrow_out_prev;
    reg signed [11:0] frac_out_prev;
    reg signed [7:0]  pass_out_prev;
    always @(posedge clk) begin
        if (rst) begin
            step_out_prev   <= 10'sd0;
            narrow_out_prev <= 8'sd0;
            frac_out_prev   <= 12'sd0;
            pass_out_prev   <= 8'sd0;
        end else begin
            if (!step_out_valid) begin
                `REQUIRE(step_out === step_out_prev);
            end
            if (!narrow_out_valid) begin
                `REQUIRE(narrow_out === narrow_out_prev);
            end
            if (!frac_out_valid) begin
                `REQUIRE(frac_out === frac_out_prev);
            end
            if (!pass_out_valid) begin
                `REQUIRE(pass_out === pass_out_prev);
            end
            step_out_prev   <= step_out;
            narrow_out_prev <= narrow_out;
            frac_out_prev   <= frac_out;
            pass_out_prev   <= pass_out;
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

    task automatic accept_frac;
        input signed [7:0] value;
        begin
            while (!frac_ready) begin
                @(negedge clk);
            end
            frac_in = value;
            frac_valid = 1'b1;
            @(negedge clk);
            frac_valid = 1'b0;
        end
    endtask

    task automatic wait_frac_out;
        integer wait_count;
        begin
            for (wait_count = 0; (wait_count < 30) && !frac_out_valid; wait_count = wait_count + 1) begin
                @(negedge clk);
            end
            `REQUIRE(frac_out_valid);
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

    integer idx;
    integer frac_sum;
    integer frac_bias_sum;
    initial begin
        done = 1'b0;
        if (FINISH) begin
            $dumpfile("iir1_hpf_tb.vcd");
            $dumpvars();
        end

        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);

        `REQUIRE(step_ready);
        accept_step(8'sd64);
        // Present another value while the HPF is busy; the subtraction must still use the accepted sample.
        `REQUIRE(!step_ready);
        step_in = -8'sd64;
        step_valid = 1'b1;
        @(negedge clk);
        step_valid = 1'b0;
        wait_step_out();
        `REQUIRE(step_out === 10'sd192);
        `REQUIRE(step_bias === 10'sd64);

        for (idx = 0; idx < 128; idx = idx + 1) begin
            accept_step(8'sd64);
            wait_step_out();
        end
        `REQUIRE(step_out === 10'sd0);
        `REQUIRE(step_bias === 10'sd256);

        for (idx = 0; idx < 128; idx = idx + 1) begin
            accept_step(-8'sd10);
            wait_step_out();
        end
        `REQUIRE(step_out === 10'sd0);
        `REQUIRE(step_bias === -10'sd40);

        for (idx = 0; idx < 256; idx = idx + 1) begin
            accept_narrow(8'sd12);
            wait_narrow_out();
        end
        `REQUIRE(narrow_out === 8'sd0);
        `REQUIRE(narrow_bias === 12'sd192);

        frac_sum = 0;
        frac_bias_sum = 0;
        for (idx = 0; idx < 768; idx = idx + 1) begin
            accept_frac((idx[1:0] == 2'b00) ? -8'sd9 : -8'sd10);
            wait_frac_out();
            if (idx >= 512) begin
                frac_sum = frac_sum + frac_out;
                frac_bias_sum = frac_bias_sum + frac_bias;
            end
        end
        `REQUIRE(frac_sum >= -8);
        `REQUIRE(frac_sum <= 8);
        `REQUIRE(frac_bias_sum >= ((-12'sd156 * 256) - 8));
        `REQUIRE(frac_bias_sum <= ((-12'sd156 * 256) + 8));

        accept_pass(8'sd37);
        wait_pass_out();
        `REQUIRE(pass_out === 8'sd0);
        `REQUIRE(pass_bias === 8'sd37);

        accept_pass(-8'sd12);
        wait_pass_out();
        `REQUIRE(pass_out === 8'sd0);
        `REQUIRE(pass_bias === -8'sd12);

        done = 1'b1;
        if (FINISH) begin
            $finish;
        end
    end
endmodule
