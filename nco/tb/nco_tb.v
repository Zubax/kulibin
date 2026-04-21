/// iverilog -Wall -Wno-timescale -y hdl/ nco_tb.v && vvp a.out

`timescale 1ns/1ns

module nco_tb;
    reg rst = 0;
    reg [5:0] fcw = 1;
    reg [5:0] pcw = 0;
    initial begin
        # 1     rst = 1;
        # 2     rst = 0;
        # 100   pcw = 32;
        # 100   fcw = 4;
        # 100   pcw = 16;
        # 100   fcw = 8;
        # 100   $finish;
    end

    reg clk = 0;
    always begin
        #1 clk = !clk;
    end

    wire [1:0] out;
    nco #(2, 6) nco_it (clk, rst, fcw, pcw, out);

    initial begin
        $dumpfile("nco_tb.vcd");
        $dumpvars();
    end
endmodule
