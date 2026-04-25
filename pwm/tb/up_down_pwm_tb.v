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

        $finish;
    end
endmodule
