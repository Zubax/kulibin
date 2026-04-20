// iverilog -Wall -Wno-timescale -y. online_integrator_tb.v && vvp a.out

`default_nettype none
`timescale 100ns / 100ns

`define REQUIRE(cond) if(!(cond)) $fatal

module online_integrator_tb;
    // Using low frequency because we want to simulate a large time interval.
    localparam CLK_HZ = 5000000;
    reg clk = 0;
    always #1 clk = ~clk;
    reg rst = 0;

    // Signal generator.
    reg [3:0] enable_clkdiv = 0;
    always @(negedge clk) enable_clkdiv <= enable_clkdiv + 1;
    wire enable_auto = (enable_clkdiv == 0);  // 312500 Hz enable rate, single-cycle pulse
    reg enable_inhibit = 0;
    reg enable_force = 0;
    wire enable = (enable_auto & ~enable_inhibit) | enable_force;
    reg signed [15:0] dxdt = 0;

    // Shared parameters.
    // Because of the large-ish leaky term, the integrator may not increase in the presence of a small nonzero input,
    // which may appear confusing in the waveform viewer.
    localparam WIN  = 16;
    localparam WOUT = 32;
    localparam LEAK = 14;

    // Backward Euler integrator.
    wire               beuler_ready;
    wire               beuler_valid;
    wire signed [31:0] beuler_x;
    online_integrator#(
        .WIN(WIN),
        .WOUT(WOUT),
        .LEAK(LEAK),
        .METHOD(1000)
    ) u_beuler (
        .clk(clk),
        .rst(rst),
        .in_valid(enable),
        .in(dxdt),
        .in_ready(beuler_ready),
        .out_valid(beuler_valid),
        .out(beuler_x)
    );

    // Trapezoidal integrator.
    wire               trapezoidal_ready;
    wire               trapezoidal_valid;
    wire signed [31:0] trapezoidal_x;
    online_integrator#(
        .WIN(WIN),
        .WOUT(WOUT),
        .LEAK(LEAK),
        .METHOD(7000)
    ) u_trapezoidal (
        .clk(clk),
        .rst(rst),
        .in_valid(enable),
        .in(dxdt),
        .in_ready(trapezoidal_ready),
        .out_valid(trapezoidal_valid),
        .out(trapezoidal_x)
    );

    // Adams-Moulton 4 (AM4) integrator, 17-bit coefficients.
    wire               am4_17_ready;
    wire               am4_17_valid;
    wire signed [31:0] am4_17_x;
    online_integrator#(
        .WIN(WIN),
        .WOUT(WOUT),
        .LEAK(LEAK),
        .METHOD(14017)
    ) u_am4_17 (
        .clk(clk),
        .rst(rst),
        .in_valid(enable),
        .in(dxdt),
        .in_ready(am4_17_ready),
        .out_valid(am4_17_valid),
        .out(am4_17_x)
    );

    // Adams-Moulton 4 (AM4) integrator, 24-bit coefficients.
    wire               am4_24_ready;
    wire               am4_24_valid;
    wire signed [31:0] am4_24_x;
    online_integrator#(
        .WIN(WIN),
        .WOUT(WOUT),
        .LEAK(LEAK),
        .METHOD(14024)
    ) u_am4_24 (
        .clk(clk),
        .rst(rst),
        .in_valid(enable),
        .in(dxdt),
        .in_ready(am4_24_ready),
        .out_valid(am4_24_valid),
        .out(am4_24_x)
    );

    // Test sequence.
    integer idx;
    integer sine_freq;
    localparam PI = 3.141592653589793;
    localparam PI2 = 2.0 * PI;
    initial begin
        $dumpfile("online_integrator_tb.vcd");
        $dumpvars();
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // 100 Hz sinewave.
        // Predicted output amplitude, continuous-time approximation:
        //
        //  omega  = 2*pi*100/312500 = 0.002010619298297468
        //  k      = 2**-14 = 6.103515625e-05
        //  G_leak = 2*sin(omega/2) / sqrt(k**2 + 4*(1-k) * sin(omega/2)**2) = 0.9995700394825299
        //
        // BDF1:    G_leak*8191             /(2*sin(omega/2)) = 4072118.2669655695
        // Tustin:  G_leak*8191*cos(omega/2)/(2*sin(omega/2)) = 4072116.2092276886
        // AM4, 24-bit:                                         4072117.5810546754
        sine_freq = 100;
        for (idx = 0; idx < CLK_HZ / 10; idx = idx + 1) begin
            dxdt = $rtoi(8191 * $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)))) + 0;
            @(negedge clk);
        end

        // 1 kHz sinewave.
        // Predicted output amplitude, continuous-time approximation, disregarding the leak:
        // BDF1:                        32767/(2*sin(pi*1000/312500)) = 1629724.332482693
        // Tustin:  cos(pi*1000/312500)*32767/(2*sin(pi*1000/312500)) = 1629641.9793359244
        sine_freq = 1000;
        for (idx = 0; idx < CLK_HZ / 100; idx = idx + 1) begin
            dxdt = $rtoi(32767 * $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)))) + 0;
            @(negedge clk);
        end

        // 10 kHz sinewave.
        // Predicted output amplitude, continuous-time approximation, disregarding the leak:
        // BDF1:                         32767/(2*sin(pi*10000/312500)) = 163244.52032618568
        // Tustin:  cos(pi*10000/312500)*32767/(2*sin(pi*10000/312500)) = 162420.30151516295
        sine_freq = 10000;
        for (idx = 0; idx < CLK_HZ / 1000; idx = idx + 1) begin
            dxdt = $rtoi(32767 * $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)))) + 0;
            @(negedge clk);
        end

        // Inject DC offset, it will bleed off later.
        dxdt = 32767;
        repeat (300) @(negedge clk);

        // Resume 1 kHz sinewave, watch the bias bleed-off.
        sine_freq = 1000;
        for (idx = 0; idx < CLK_HZ / 100; idx = idx + 1) begin
            dxdt = $rtoi(32767 * $sin(PI2 * sine_freq * ($itor(idx) / $itor(CLK_HZ)))) + 0;
            @(negedge clk);
        end

        // Feed zero DC and ensure the integrators eventually settle to zero.
        dxdt = 0;
        repeat (CLK_HZ) @(negedge clk);
        `REQUIRE(beuler_x === 0);
        `REQUIRE(trapezoidal_x === 0);
        `REQUIRE(am4_17_x === 0);
        `REQUIRE(am4_24_x === 0);

        // Clock edge cases.
        enable_inhibit = 1;
        repeat (50) @(negedge clk);
        enable_inhibit = 0;
        enable_force = 1;
        repeat (50) @(negedge clk);
        enable_force = 0;
        repeat (50) @(negedge clk);

        $finish;
    end

endmodule
