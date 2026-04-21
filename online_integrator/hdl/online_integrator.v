/// Integrates a PCM signal using the specified method, assuming dt=1.
///
/// The input signal must be zero-mean (preliminary DC unbiasing is required).
/// The integrator is leaky to bleed DC bias that may accumulate due to transient input biasing or quantization errors.
/// Due to the leak term, the internal computation is done in a wider bit width than the output to avoid insensitivity
/// to small DC biases.
///
/// The output gain is specified per the integration method below.

`default_nettype none

module online_integrator#(
    /// Bit width of the input signed PCM samples, including the sign bit.
    parameter WIN = 16,

    /// Integral width, including sign bit.
    /// Given maximum DC signal A=abs(-(2^(WIN-1))) applied for t seconds with the sampling frequency f_s,
    /// the maximum integrator output is A*f_s*t, and the required bit width is ceil(log2(A*f_s*t)).
    /// The input signal should be DC-free, which will prevent the overflow, and the leak term will eventually
    /// bleed the accumulated DC.
    ///
    /// E.g., given WIN=16, f_s=312500 Hz, t=2 s, this amounts to 35 bits plus sign = at least 36 bits.
    parameter WOUT = 36,

    /// The leak is needed to avoid long-term integrator bias or overflow in the presence of transient input biasing.
    /// To avoid passband droop, the leak term should be very small.
    /// The leak function is defined as part of a two-step integration process:
    ///
    ///     y[n]' = integrate(y, x)         ; first step --- specific integration method update
    ///     y[n]  = (1-k) y[n]'             ; second step --- apply the leak term
    ///
    /// For 0 < k << 1, let k = 2^-LEAK. This is a standard IIR single-pole filter with a pole at z=1-k.
    /// Eliminate multiplication requiring that LEAK is an integer:
    ///
    ///     y[n] = y[n]' - y[n]' k                  ; equivalent form of the leak function
    ///     y[n] = y[n]' - (y[n]' >>> LEAK)
    ///
    /// Where the shift needs to be done with rounding-to-nearest to avoid round-off bias.
    /// The leak may be arbitrarily large, even exceeding WOUT, because internally we use a wider representation.
    ///
    /// This form resembles the exponential moving average IIR, which can be used to approximate its influence
    /// on the integrated signal. We say "approximate" because the full model needs to consider the particular
    /// integration method used. For the simple single-pole EMA IIR, refer to the iir1_hpf module.
    ///
    /// Larger leak values result in longer time constants (lower cutoff frequency, less attenuation at a given freq).
    parameter LEAK = 22,

    /// Integration method to use:
    ///
    ///  1000   - Backward Euler, aka BDF1, AM1, etc.
    ///  2000   - BDF2 (not implemented).
    ///  7000   - Trapezoidal (Tustin, AM2). Good accuracy and stability tradeoff.
    /// 14017   - Adams–Moulton 4 (AM4) with 17-bit coefficients, single-multiplier pipeline with 10 clk latency.
    /// 14024   - Ditto, 24-bit coefficients.
    ///
    /// Numerical integrators often rely on convolution of the input signal with a kernel that approximates integration;
    /// we can effectively repurpose the fir.v module for integration by choosing the appropriate kernel.
    parameter METHOD = 14017
)(
    input wire clk,
    input wire rst,

    // Input PCM samples.
    // in_ready goes low for a few cycles while the integrator is busy.
    // in_valid cannot stay high for more than one clk cycle.
    // in_valid while in_ready is low is ignored.
    input  wire                  in_valid,
    output wire                  in_ready,
    input  wire signed [WIN-1:0] in,

    // Output PCM samples, after integration. The output remains stable between valid pulses.
    output wire                   out_valid,
    output wire signed [WOUT-1:0] out
);
    // The internal width is larger by LEAK bits to avoid insensitivity to small DC biases.
    // Otherwise, the leak term will not be able to bleed biases up to LEAK bits wide.
    localparam WX = WOUT + LEAK;
    wire                integrator_valid;  // Pulsed when the integrator is updated with the new result.
    reg signed [WX-1:0] integrator;

    // Input right-zero-padded to ensure correct scaling.
    localparam WXIN = WIN + LEAK;
    wire signed [WXIN-1:0] xin = $signed({in, {LEAK{1'b0}}});

    // Leak logic.
    // We need an intermediate register step because the rounding and subtraction form a very long combinational path.
    localparam WL = WX - LEAK;  // Width after the leak shift
    wire signed [WL-1:0] leak_;
    // Computes (integrator>>>LEAK) with rounding.
    round_signed#(.WIN(WX), .WOUT(WL)) round_leak (.din(integrator), .dout(leak_));
    reg  signed [WL-1:0] leak_d;
    wire signed [WX-1:0] leaked_next = integrator - $signed({{LEAK{leak_d[WL-1]}}, leak_d});

    // Rounded integrator output in the correct width.
    cast_signed_p#(.WIN(WX), .MSB(0), .LSB(LEAK)) round_out (
        .clk(clk),
        .rst(rst),
        .in_valid(integrator_valid),
        .in_data(integrator),
        .out_valid(out_valid),
        .out_data(out)
    );

    generate
        // Backward Euler, aka BDF1, AM1, ...:
        //
        //      y[n] = y[n-1] + x[n]
        //
        // Given input:
        //
        //      x[n] = D cos(n omega + phi)
        //      omega = 2 pi f/f_s
        //
        // the output amplitude is, continuous-time approximation (disregarding the leak):
        //
        //                     D
        //      A_out = ----------------
        //               2 sin(omega/2)
        //
        // Note that this is an approximation that does not consider discretization effects.
        if (METHOD == 1000) begin : g_backward_euler
            reg [1:0] state;
            wire signed [WX-1:0] next = integrator + $signed({{(WX-WXIN){xin[WXIN-1]}}, xin});
            assign integrator_valid = (state == 1); // next output available on the next clk already
            assign in_ready         = (state == 0); // ... but we need more cycles to apply the leak
            always @ (posedge clk) begin
                if (rst) begin
                    integrator <= 0;
                    leak_d     <= 0;
                    state      <= 0;
                end else begin
                    case (state)
                        0: if (in_valid) begin
                            integrator <= next;
                            state      <= 1;
                        end
                        1: begin
                            leak_d <= leak_;
                            state  <= 2;
                        end
                        2: begin
                            // Important: the conventional leak form is: y[n+1] = (1-k) y[n] + x[n]
                            // The leak is applied to the prev integrator state without affecting the input sample.
                            // Hence, we pass the integrator to the output before applying the leak.
                            // The applied leak has effect only in the next sample, per the definition above.
                            // If we were to pass leaked_next to the output, we would be attenuating the input sample.
                            integrator <= leaked_next;
                            state      <= 0;
                        end
                        default: state <= 0;
                    endcase
                end
            end
        end

        // Trapezoidal (Tustin, AM2):
        //
        //      y[n] = y[n-1] + (x[n] + x[n-1])/2
        //
        // Given input:
        //
        //      x[n] = D cos(n omega + phi)
        //      omega = 2 pi f/f_s
        //
        // the output amplitude is, continuous-time approximation (disregarding the leak):
        //
        //               D cos(omega/2)
        //      A_out = ----------------
        //               2 sin(omega/2)
        //
        // Note that this is an approximation that does not consider discretization effects.
        else if (METHOD == 7000) begin : g_trapezoidal
            reg [1:0] state;
            reg  signed [WIN-1:0] x[0:1];
            wire signed [WIN-1:0] addend_next;  // (x[n]+x[n-1])/2 with rounding-to-nearest, ties-to-even
            round_signed#(.WIN(WIN+1), .WOUT(WIN)) avg (
                .din($signed({x[0][WIN-1], x[0]}) + $signed({x[1][WIN-1], x[1]})),
                .dout(addend_next)
            );
            reg  signed [WXIN-1:0] addend;
            wire signed [WX-1:0] next = integrator + $signed({{(WX-WXIN){addend[WXIN-1]}}, addend});
            assign integrator_valid = (state == 3);
            assign in_ready         = (state == 0);
            always @ (posedge clk) begin
                if (rst) begin
                    integrator <= 0;
                    leak_d     <= 0;
                    state      <= 0;
                    x[0]       <= 0;
                    x[1]       <= 0;
                    addend     <= 0;
                end else begin
                    case (state)
                        0: if (in_valid) begin
                            x[0] <= in;     // latch the inputs to break the long combinational path on arithmetics
                            x[1] <= x[0];
                            integrator <= leaked_next;  // complete the leak from the previous (sic) sample
                            state <= 1;
                        end
                        1: begin
                            addend <= $signed({addend_next, {LEAK{1'b0}}}); // right-zero-pad the addend
                            state <= 2;
                        end
                        2: begin
                            integrator <= next;
                            state <= 3;
                        end
                        3: begin
                            leak_d <= leak_;
                            state <= 0;
                        end
                        default: state <= 0;
                    endcase
                end
            end
        end

        // Adams–Moulton 4 (AM4):
        //
        //                      9 x[n] + 19 x[n-1] - 5 x[n-2] + x[n-3]
        //      y[n] = y[n-1] + --------------------------------------
        //                                       24
        //
        // Given input:
        //
        //      x[n] = D cos(n omega + phi)
        //      omega = 2 pi f/f_s
        //
        // the output amplitude is, continuous-time approximation (disregarding the leak):
        //
        //      A_out = (D/(48*sin(omega/2))) * sqrt(468 + 142*cos(omega) - 52*cos(2*omega) + 18*cos(3*omega))
        //
        // Note that this is an approximation that does not consider discretization effects.
        // The method is implemented using the FIR filter with the kernel [+9/24, +19/24, -5/24, +1/24].
        else if (METHOD / 1000 == 14) begin : g_am4
            localparam WK = METHOD % 1000; // coefficient bit width
            localparam KERNEL = (WK == 17) ? "online_integrator.am4.q1.16.fir.memb"
                              : (WK == 24) ? "online_integrator.am4.q1.23.fir.memb"
                              : "INVALID";
            wire fir_done;
            wire signed [WIN-1:0] fir_out;
            fir#(
                .ORDER(3),
                .COEF_FILE(KERNEL),
                .QIN  (1000 + WIN - 1), // q1.(WIN-1)
                .QCOEF(1000 + WK  - 1), // q1.(WK-1)
                .QOUT (1000 + WIN - 1)  // q1.(WIN-1)
            ) u_convolution (
                .clk(clk),
                .rst(rst),
                .in_valid(in_valid),
                .in_ready(in_ready),
                .in_data(in),
                .out_valid(fir_done),
                .out_data(fir_out)
            );
            wire signed [WXIN-1:0] addend = $signed({fir_out, {LEAK{1'b0}}}); // right-zero-pad for correct scaling
            wire signed [WX-1:0] next = integrator + $signed({{(WX-WXIN){addend[WXIN-1]}}, addend});
            reg [1:0] state;
            assign integrator_valid = (state == 1);
            always @ (posedge clk) begin
                if (rst) begin
                    integrator <= 0;
                    leak_d     <= 0;
                    state      <= 0;
                end else begin
                    case (state)
                        // fir_done cannot go high more often than once every 4 clk, so there's no risk of missing it.
                        0: if (fir_done) begin
                            integrator <= next;
                            state      <= 1;
                        end
                        1: begin
                            leak_d <= leak_;
                            state  <= 2;
                        end
                        2: begin
                            integrator <= leaked_next;
                            state      <= 0;
                        end
                        default: state <= 0;
                    endcase
                end
            end
        end

        else begin : g_invalid
            initial $fatal;
        end
    endgenerate
endmodule
