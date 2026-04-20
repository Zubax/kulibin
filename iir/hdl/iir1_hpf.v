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
    /// Input and output sample width, signed.
    parameter W = 16,

    /// The filter constant k defined as alpha = 2^-k. See the response model above.
    /// This value may be arbitrarily large (may exceed W), because internally we use a wider representation.
    parameter K = 16
)(
    input wire clk,
    input wire rst,

    // Input sample.
    // Input samples are ignored unless in_ready is high.
    output wire                in_ready,
    input  wire                in_valid,
    input  wire signed [W-1:0] in,

    // Output result.
    // The output remains unchanged between valid pulses.
    output wire                out_valid,
    output wire signed [W-1:0] out,

    // Optional diagnostic output: the current low-frequency (DC) bias estimate.
    output wire signed [W-1:0] bias
);
    // Extract the low-frequency signal.
    wire lpf_valid;
    wire signed [W-1:0] lpf;
    iir1_lpf#(.W(W), .K(K)) u_lpf (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in(in),
        .in_ready(in_ready),
        .out_valid(lpf_valid),
        .out(lpf)
    );
    assign bias = lpf;

    // Subtract the low-frequency signal from the input to get the high-pass result.
    cast_signed_p#(.WIN(W+1), .MSB(1), .LSB(0)) sub (
        .clk(clk),
        .rst(rst),
        .in_valid(lpf_valid),
        .in_data($signed({in[W-1], in}) - $signed({lpf[W-1], lpf})),
        .out_valid(out_valid),
        .out_data(out)
    );
endmodule
