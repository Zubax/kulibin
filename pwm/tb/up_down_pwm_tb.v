// iverilog -Wall -Wno-timescale -y. up_down_pwm_tb.v && vvp a.out

`timescale 1ns/1ns
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module up_down_pwm_tb;
    localparam W = 8;
    localparam SHADOW_RELOAD_TOP = 1;
    localparam SHADOW_RELOAD_BOT = 2;

    reg clk = 0;
    always #1 clk = !clk;

    reg rst = 1;
    reg [W-1:0] top     = 4;
    reg [W-1:0] compare = 1;

    wire at_top_both;
    wire at_bot_both;
    wire out_both;
    up_down_pwm#(W) pwm_both (
        .clk(clk),
        .rst(rst),
        .top(top),
        .compare(compare),
        .at_top(at_top_both),
        .at_bot(at_bot_both),
        .out(out_both)
    );

    wire at_top_top;
    wire at_bot_top;
    wire out_top;
    up_down_pwm #(.W(W), .SHADOW_RELOAD(SHADOW_RELOAD_TOP)) pwm_top (
        .clk(clk),
        .rst(rst),
        .top(top),
        .compare(compare),
        .at_top(at_top_top),
        .at_bot(at_bot_top),
        .out(out_top)
    );

    wire at_top_bot;
    wire at_bot_bot;
    wire out_bot;
    up_down_pwm #(.W(W), .SHADOW_RELOAD(SHADOW_RELOAD_BOT)) pwm_bot (
        .clk(clk),
        .rst(rst),
        .top(top),
        .compare(compare),
        .at_top(at_top_bot),
        .at_bot(at_bot_bot),
        .out(out_bot)
    );

    reg [W-1:0] top_wave     = 4;
    reg [W-1:0] compare_wave = 0;
    wire at_top_wave;
    wire at_bot_wave;
    wire out_wave;
    up_down_pwm#(W) pwm_wave (
        .clk(clk),
        .rst(rst),
        .top(top_wave),
        .compare(compare_wave),
        .at_top(at_top_wave),
        .at_bot(at_bot_wave),
        .out(out_wave)
    );

    task automatic wait_top_latched;
        integer guard;
        begin
            guard = 0;
            while (at_top_both !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 64);
            end
            @(negedge clk);
        end
    endtask

    task automatic wait_bot_latched;
        integer guard;
        begin
            guard = 0;
            while (at_bot_both !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 64);
            end
            @(negedge clk);
        end
    endtask

    task automatic wait_bot_latched_bot;
        integer guard;
        begin
            guard = 0;
            while (at_bot_bot !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 64);
            end
            @(negedge clk);
        end
    endtask

    task automatic load_wave;
        input [W-1:0] top_value;
        input [W-1:0] compare_value;
        integer guard;
        begin
            top_wave     = top_value;
            compare_wave = compare_value;

            guard = 0;
            while ((pwm_wave.top_r !== top_value) || (pwm_wave.compare_r !== compare_value)) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end
        end
    endtask

    task automatic wait_wave_bot_edge;
        integer guard;
        begin
            guard = 0;
            while (at_bot_wave === 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end

            while (at_bot_wave !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end
        end
    endtask

    task automatic check_wave_period;
        input [W-1:0] top_value;
        input [W-1:0] compare_value;
        input integer expected_high_count;
        integer guard;
        integer high_count;
        integer period;
        begin
            load_wave(top_value, compare_value);
            wait_wave_bot_edge();

            period = 2 * top_value;
            high_count = 0;
            for (guard = 0; guard < period; guard = guard + 1) begin
                if (out_wave === 1'b1) begin
                    high_count = high_count + 1;
                end
                @(negedge clk);
            end

            `REQUIRE(at_bot_wave === 1'b1);
            `REQUIRE(high_count == expected_high_count);
        end
    endtask

    task automatic check_wave_hold;
        input [W-1:0] top_value;
        input [W-1:0] compare_value;
        input expected_out;
        input integer cycles;
        integer idx;
        begin
            load_wave(top_value, compare_value);
            for (idx = 0; idx < cycles; idx = idx + 1) begin
                @(negedge clk);
                `REQUIRE(out_wave === expected_out);
            end
        end
    endtask

    initial begin
        $dumpfile("up_down_pwm_tb.vcd");
        $dumpvars();

        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        `REQUIRE(pwm_both.top_r === top);
        `REQUIRE(pwm_top.top_r === top);
        `REQUIRE(pwm_bot.top_r === top);
        `REQUIRE(pwm_both.compare_r === compare);
        `REQUIRE(pwm_top.compare_r === compare);
        `REQUIRE(pwm_bot.compare_r === compare);

        wait_bot_latched();
        compare = 2;
        `REQUIRE(pwm_both.compare_r === 1);
        `REQUIRE(pwm_top.compare_r === 1);
        `REQUIRE(pwm_bot.compare_r === 1);

        wait_top_latched();
        `REQUIRE(pwm_both.compare_r === 2);
        `REQUIRE(pwm_top.compare_r === 2);
        `REQUIRE(pwm_bot.compare_r === 1);

        wait_bot_latched();
        `REQUIRE(pwm_both.compare_r === 2);
        `REQUIRE(pwm_top.compare_r === 2);
        `REQUIRE(pwm_bot.compare_r === 2);

        wait_top_latched();
        compare = 3;
        `REQUIRE(pwm_both.compare_r === 2);
        `REQUIRE(pwm_top.compare_r === 2);
        `REQUIRE(pwm_bot.compare_r === 2);

        wait_bot_latched();
        `REQUIRE(pwm_both.compare_r === 3);
        `REQUIRE(pwm_top.compare_r === 2);
        `REQUIRE(pwm_bot.compare_r === 3);

        wait_top_latched();
        `REQUIRE(pwm_both.compare_r === 3);
        `REQUIRE(pwm_top.compare_r === 3);
        `REQUIRE(pwm_bot.compare_r === 3);

        top = 0;
        wait_bot_latched_bot();
        `REQUIRE(pwm_bot.top_r === 0);

        top = 5;
        repeat (3) @(negedge clk);
        `REQUIRE(pwm_bot.top_r === 5);
        `REQUIRE(pwm_bot.counter !== 0);

        wait_bot_latched_bot();
        `REQUIRE(pwm_bot.top_r === 5);

        check_wave_period(4, 0, 0);
        check_wave_period(4, 1, 2);
        check_wave_period(4, 3, 6);
        check_wave_period(4, 4, 8);

        check_wave_period(4, 0, 0);
        check_wave_hold(4, 6, 1'b0, 16);
        check_wave_period(4, 4, 8);
        check_wave_hold(4, 6, 1'b1, 16);
        check_wave_hold(0, 3, 1'b1, 8);

        $finish;
    end
endmodule
