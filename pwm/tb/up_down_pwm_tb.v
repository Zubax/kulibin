// iverilog -Wall -Wno-timescale -y. up_down_pwm_tb.v && vvp a.out

`timescale 1ns/1ns

module up_down_pwm_tb;
    reg clk = 0;
    always #1 clk = !clk;

    reg rst = 0;
    reg [7:0] top     = 8;
    reg [7:0] compare = 4;
    initial begin
        # 1     rst = 1;
        # 2     rst = 0;

        # 79    compare = 0;
        # 79    compare = 1;
        # 79    compare = 2;
        # 79    compare = 3;
        # 79    compare = 4;
        # 79    compare = 5;
        # 79    compare = 6;
        # 79    compare = 7;
        # 79    compare = 8;
        # 79    compare = 9;
        # 79    compare = 0;
        # 79    compare = 9;

        # 79    top = 3;
        # 79    compare = 2;
        # 79    top = 0;

        # 79    top = 255;
        # 79    compare = 254;

        # 1500 $finish;
    end

    wire at_top;
    wire at_bot;
    wire out;
    up_down_pwm#(8) pwm (
        .clk(clk),
        .rst(rst),
        .top(top),
        .compare(compare),
        .at_top(at_top),
        .at_bot(at_bot),
        .out(out)
    );

    initial begin
        $dumpfile("up_down_pwm_tb.vcd");
        $dumpvars();
    end
endmodule
