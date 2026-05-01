/// A first-order IIR HPF defined in terms of its LPF counterpart. See iir1_lpf.v for details.
/// The difference equation is:
///
///     y[n] = x[n] - x[n-1] + r * y[n-1]
///
/// The equivalent form used here is:
///
///     y[n] = x[n] - m[n]
///     m[n] = m[n-1] + alpha (x[n] - m[n-1])
///
/// where alpha=2^-k and r=1-alpha. The frequency response is:
///
///     H_hpf(z) = 1 - H_lpf(z)
///
/// In Python, utilizing H_iir1_lpf() from iir1_lpf:
///
///     def H_iir1_hpf(f: float, f_s: float, k: int) -> complex:
///         return 1 - H_iir1_lpf(f, f_s, k)

`default_nettype none

module iir1_hpf#(
    /// Input sample width, sign bit included.
    parameter WIN = 16,

    /// The filter constant k defined as alpha = 2^-k. See the response model above.
    /// This value may be arbitrarily large (may exceed WIN), because internally we use a wider representation.
    parameter K = 16,

    /// Output sample width, sign bit included. Set greater than WIN to expose fractional LSbs.
    /// The numeric scale is the same as the input left-shifted by WOUT-WIN bits; using Q-format, the integer part
    /// is the same as the input, and the fractional part is extended.
    /// By default this preserves K fractional bits, matching the filter update quantum.
    parameter WOUT = WIN + K
)(
    input wire clk,
    input wire rst,

    // Input sample.
    // Input samples are ignored unless in_ready is high.
    output wire                  in_ready,
    input  wire                  in_valid,
    input  wire signed [WIN-1:0] in,

    // Output result.
    // The output remains unchanged between valid pulses.
    output wire                   out_valid,
    output wire signed [WOUT-1:0] out,

    // Optional diagnostic output: the current low-frequency (DC) bias estimate. Always full precision.
    output wire signed [WIN+K-1:0] bias
);
    // Extract the low-frequency component. Use full-precision representation to avoid added quantization noise.
    wire bias_valid;
    iir1_lpf#(.WIN(WIN), .K(K), .WOUT(WIN+K)) u_lpf (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in(in),
        .in_ready(in_ready),
        .out_valid(bias_valid),
        .out(bias)
    );

    // Delay the input to ensure the final subtraction is done against the matching input sample in case it is variable.
    reg signed [WIN-1:0] in_z;
    reg signed [WIN-1:0] in_z_d;
    always @(posedge clk) begin
        if (rst) begin
            in_z   <= {WIN{1'b0}};
            in_z_d <= {WIN{1'b0}};
        end else begin
            if (in_valid && in_ready) begin
                in_z <= in;
            end
            in_z_d <= in_z;
        end
    end

    // Subtract the low-frequency component from the input to get the high-pass result.
    cast_signed_p#(.WIN(WIN+K+1), .MSB(1), .LSB(WIN+K-WOUT)) sub (
        .clk(clk),
        .rst(rst),
        .in_valid(bias_valid),
        .in_data($signed({in_z_d[WIN-1], in_z_d, {K{1'b0}}}) - $signed({bias[WIN+K-1], bias})),
        .out_valid(out_valid),
        .out_data(out)
    );
endmodule
