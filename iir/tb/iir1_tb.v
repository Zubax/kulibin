// iverilog -Wall -Wno-timescale -y. iir1_tb.v && vvp a.out

`default_nettype none
`timescale 100ns / 100ns

`define REQUIRE(cond) if(!(cond)) $fatal

module iir1_tb;
    localparam CLK_HZ = 5000000;
    reg [63:0] count_5MHz = 0;
    always #1 count_5MHz = count_5MHz + 1;
    wire clk = count_5MHz[0];
    reg rst = 0;
    reg [31:0] freq_div_cnt = 0;
    localparam DATA_FREQ = 312500;
    localparam FREQ_DIV = CLK_HZ / DATA_FREQ;
    always @(negedge clk) begin
        freq_div_cnt <= (freq_div_cnt == (FREQ_DIV - 1)) ? 0 : (freq_div_cnt + 1);
    end
    wire in_valid = freq_div_cnt == 0;

    // The IIR1 low-pass filter.
    reg signed [15:0] in_data = 0;
    wire in_lpf_ready;
    wire out_lpf_valid;
    wire signed [15:0] out_lpf_data;
    iir1_lpf#(
        .W(16),
        .K(8)  // cutoff around 0.33 kHz at 312.5 kHz sample rate
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in(in_data),
        .in_ready(in_lpf_ready),
        .out_valid(out_lpf_valid),
        .out(out_lpf_data)
    );

    // The IIR1 high-pass filter.
    wire in_hpf_ready;
    wire out_hpf_valid;
    wire signed [15:0] out_hpf_data;
    iir1_hpf#(
        .W(16),
        .K(8)
    ) dut_hpf (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in(in_data),
        .in_ready(in_hpf_ready),
        .out_valid(out_hpf_valid),
        .out(out_hpf_data),
        .bias()  // unused
    );

    integer idx;
    integer sine_freq;
    localparam PI = 3.141592653589793;
    localparam PI2 = 2.0 * PI;
    initial begin
        $dumpfile("iir1_tb.vcd");
        $dumpvars();
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // Sinewave with zero DC bias.
        sine_freq = 3000;
        for (idx = 0; idx < CLK_HZ / 100; idx = idx + 1) begin
            in_data = $rtoi(32767 * $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)))) + 0;
            @(negedge clk);
        end

        // Sinewave with a positive DC bias.
        sine_freq = 3000;
        for (idx = 0; idx < CLK_HZ / 300; idx = idx + 1) begin
            in_data = $rtoi(16383 * $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)))) + 16383;
            @(negedge clk);
        end

        // Sinewave with a negative DC bias.
        sine_freq = 3000;
        for (idx = 0; idx < CLK_HZ / 300; idx = idx + 1) begin
            in_data = $rtoi(16383 * $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)))) - 16383;
            @(negedge clk);
        end

        // Pure DC.
        in_data = +16383;
        for (idx = 0; idx < CLK_HZ / 100; idx = idx + 1) begin
            @(negedge clk);
        end
        `REQUIRE(out_lpf_data === +16383);
        `REQUIRE(out_hpf_data === 0);

        // Pure DC.
        in_data = -10;
        for (idx = 0; idx < CLK_HZ / 100; idx = idx + 1) begin
            @(negedge clk);
        end
        `REQUIRE(out_lpf_data === -10);
        `REQUIRE(out_hpf_data === 0);

        $finish;
    end
endmodule
