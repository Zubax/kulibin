/// iverilog -Wall -Wno-timescale -y. sdadc_to_pwm_tb.v && vvp a.out

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

module sdadc_to_pwm_tb;
    // The clock speed approximates the real clock rate of the fabric.
    localparam CLK_HZ = 100_000_000;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;

    // Sigma-delta clock near 20 MHz.
    localparam FREQ_RATIO = 5;
    wire sd_enable_clk;
    freqdivc#(FREQ_RATIO) sd_freqdivc(.clk(clk), .rst(rst), .enable(1'b1), .out(sd_enable_clk));
    reg [1:0] sd_enable_r = 0;
    always @(negedge clk) begin
        sd_enable_r[1] <= sd_enable_r[0];
        sd_enable_r[0] <= sd_enable_clk;
    end
    wire sd_enable = sd_enable_r[0] && !sd_enable_r[1];

    // Sigma-delta modulator.
    real sd_value = 0;
    wire sd_bit;
    sd1_real sd_mod(.clk(clk), .rst(rst), .enable(sd_enable), .x(sd_value), .y(sd_bit));

    // DUT
    localparam W = 12;
    localparam RCIC = 128;
    wire pwm_pos;
    wire pwm_neg;
    reg out_enable = 1;
    wire [W-1:0] pcm;
    sdadc_to_pwm#(
        .W(W),
        .FREQ_RATIO(FREQ_RATIO),
        .RCIC(RCIC)
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_sd_bit_valid(sd_enable),
        .in_sd_bit(sd_bit),
        .out_enable(out_enable),
        .out_pwm_pos(pwm_pos),
        .out_pwm_neg(pwm_neg),
        .out_pcm_valid(),
        .out_pcm(pcm)
    );
    wire [7:0] led = $unsigned(pcm[W-1:W-8]);
    localparam PWM_TOP = RCIC * FREQ_RATIO;
    real PWM_FREQ = $itor(CLK_HZ) / $itor(2 * PWM_TOP);

    // Simple no-shoot-through invariant check at every cycle.
    always @(posedge clk) begin
        if (!rst) begin
            `REQUIRE((pwm_pos && pwm_neg) === 0);
            if (!out_enable) begin
                `REQUIRE((pwm_pos || pwm_neg) === 0);
            end
        end
    end

    // Test sequence.
    integer idx;
    integer sine_freq;
    localparam PI = 3.141592653589793;
    localparam PI2 = 2.0 * PI;
    initial begin
        $dumpfile("sdadc_to_pwm_tb.vcd");
        $dumpvars();

        $display("Expected PWM top: %d", PWM_TOP);
        $display("PWM frequency: %f Hz", PWM_FREQ);
        $display("PWM period: %f us", 1e6 / PWM_FREQ);

        rst = 1;
        repeat(2) @(negedge clk);
        rst = 0;
        repeat(2) @(negedge clk);

        // Feed maximum input
        sd_value = +1.0;
        repeat (RCIC * 64) @(negedge clk);

        // Feed the maximum input with bit stuffing
        sd_value = +63.0 / 64.0;
        repeat (RCIC * 64) @(negedge clk);

        // Feed minimum input
        sd_value = -1.0;
        repeat (RCIC * 64) @(negedge clk);

        // Feed the minimum input with bit stuffing
        sd_value = -63.0 / 64.0;
        repeat (RCIC * 64) @(negedge clk);

        // Feed zero input
        sd_value = 0.0;
        repeat (RCIC * 64) @(negedge clk);

        // Feed sinewave
        sine_freq = 3000;
        for (idx = 0; idx < CLK_HZ / 1000; idx = idx + 1) begin
            sd_value = $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)));
            @(negedge clk);
        end

        // Disengage
        out_enable = 0;
        sine_freq = 10000;
        for (idx = 0; idx < 1000; idx = idx + 1) begin
            sd_value = $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)));
            @(negedge clk);
        end

        $finish;
    end
endmodule
