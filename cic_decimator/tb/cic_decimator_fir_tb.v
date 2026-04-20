/// iverilog -Wall -Wno-timescale -y. cic_decimator_fir_tb.v && vvp a.out

`default_nettype none
`timescale 1ns / 1ns

`define REQUIRE(cond) if(!(cond)) $fatal


/// First-order sigma-delta modulator for testing. Accepts real input in [-1, +1], emits 1-bit output.
module sd1_real(input wire clk, input wire rst, input wire enable, input real x, output reg y);
    real acc = 0;
    real fb = 0;
    always @(posedge clk) begin
        if (rst) begin
            acc = 0;
            y   <= 1'b0;
        end else if (enable) begin
            fb  = y ? 1.0 : -1.0;   // 1-bit DAC
            acc = acc + (x - fb);   // integrate error
            y   <= (acc >= 0.0);    // 1-bit quantizer
        end
    end
endmodule


module cic_decimator_fir_tb;
    localparam CLK_HZ = 200000000;
    reg [63:0] count_200MHz = 0;
    always begin
        #2 count_200MHz = count_200MHz + 1;
        #3 count_200MHz = count_200MHz + 1;
    end

    wire clk = count_200MHz[0];
    reg rst = 0;

    reg sd_enable = 0;
    reg cicfir_enable = 0;
    always @(negedge clk) begin
        sd_enable <= (count_200MHz % 20) == 0;  // 20 MHz input rate
        cicfir_enable <= sd_enable;  // lag by 1 clk to synchronize with sd_mod
    end

    // Sigma-delta modulator.
    real sd_input = 0;
    wire sd_mod;
    sd1_real sd1(.clk(clk), .rst(rst), .enable(sd_enable), .x(sd_input), .y(sd_mod));

    // The CIC+FIR decimator.
    wire out_valid;
    wire signed [15:0] out_data;
    cic_decimator_fir#(
        .WIN(1),    // sign bit only
        .RCIC(64),  // 20 MHz in / 64 = 312.5 kHz out
        .NCIC(3),
        .NFIR(12),  // low order reduces the group delay and the logic pipeline delay
        .WOUT(16),  // mapped into [-32768,+32767] full scale, aka q1.15 [-1,+1)
        .WK(17),    // q1.16 FIR coefficients
        .KERNEL("62eab2361fc4dbf9.fir.memb")
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(cicfir_enable),
        .in_data(~sd_mod),
        .out_valid(out_valid),
        .out_data(out_data)
    );

    integer idx;
    integer sine_freq;
    localparam PI = 3.141592653589793;
    localparam PI2 = 2.0 * PI;
    initial begin
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // Feed low-frequency sinewave for a few periods. This is well inside the pass band.
        // CIC will cause droop, but the FIR will compensate for it.
        sine_freq = 10000;
        for (idx = 0; idx < 2 * (CLK_HZ / sine_freq); idx = idx + 1) begin
            sd_input = $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)));
            @(negedge clk);
        end

        // Feed high-frequency sinewave for a few periods. This should be mostly attenuated.
        // CIC will cause only weak attenuation, but the FIR will provide strong suppression.
        sine_freq = 100000;
        for (idx = 0; idx < 6 * (CLK_HZ / sine_freq); idx = idx + 1) begin
            sd_input = $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)));
            @(negedge clk);
        end

        // Feed zero.
        sd_input = 0;
        repeat (50 * (CLK_HZ / 1000000)) @(negedge clk);

        // Feed max.
        sd_input = 1.0;
        repeat (50 * (CLK_HZ / 1000000)) @(negedge clk);

        // Feed min.
        sd_input = -1.0;
        repeat (50 * (CLK_HZ / 1000000)) @(negedge clk);

        // Feed zero.
        sd_input = 0;
        repeat (50 * (CLK_HZ / 1000000)) @(negedge clk);

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_fir_tb.vcd");
        $dumpvars();
    end
endmodule
