/// A simple, highly accurate single-pole IIR LPF with low phase delay. The difference equation is:
///
///     y[n] = y[n-1] + alpha (x[n] - y[n-1])
///
/// Where alpha = 2^-k. The frequency response is:
///
///                     alpha
///     H_lpf(z) = -------------------
///                1 - (1-alpha) z^-1
///
/// Where z = e^(j omega), omega = 2 pi f/f_s.
/// In Python:
///
///     import numpy as np
///
///     def H_iir1_lpf(f: float, f_s: float, k: int) -> complex:
///         alpha = 2**-int(k)
///         w = 2*np.pi * f / f_s
///         z = np.exp(-1j * w)  # equals z^-1 on the unit circle
///         return alpha / (1 - (1 - alpha) * z)
///
///     def gain_at_f(f: float, f_s: float, k: int) -> float:
///         return float(np.abs(H_iir1_lpf(f, f_s, k)))

`default_nettype none

module iir1_lpf#(
    /// Input and output sample width, signed.
    parameter W = 16,

    /// The filter constant k defined as alpha = 2^-k.
    /// Greater values result in a longer time constant (lower cutoff frequency); see the response model above.
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
    output wire signed [W-1:0] out
);
    localparam WX = W + K + 1;  // Internal representation width to eliminate DC residue.

    wire signed [WX-1:0] x = {in, {(WX-W){1'b0}}};  // x[n]   in q1.(WX-1)
    reg  signed [WX-1:0] y_1;                       // y[n-1] in q1.(WX-1)

    // Compute alpha*(x[n]-y[n-1]) with the correct rounding and saturation.
    wire                   alpha_x_y_1_valid;
    wire signed [WX-K-1:0] alpha_x_y_1;    // alpha * (x[n] - y[n-1])
    cast_signed_p#(.WIN(WX+1), .MSB(1), .LSB(K)) mult_alpha (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid && in_ready),
        .in_data($signed({x[WX-1], x}) - $signed({y_1[WX-1], y_1})),
        .out_valid(alpha_x_y_1_valid),
        .out_data(alpha_x_y_1)
    );

    // Compute y[n] with saturation.
    wire                 y_next_valid;
    wire signed [WX-1:0] y_next;
    cast_signed_p#(.WIN(WX+1), .MSB(1), .LSB(0)) y_sum (
        .clk(clk),
        .rst(rst),
        .in_valid(alpha_x_y_1_valid),
        .in_data($signed({y_1[WX-1], y_1}) + $signed({{(K+1){alpha_x_y_1[WX-K-1]}}, alpha_x_y_1})),
        .out_valid(y_next_valid),
        .out_data(y_next)
    );

    // Compute the output, which is a narrower form of y[n].
    cast_signed_p#(.WIN(WX), .MSB(0), .LSB(WX-W)) y_out (
        .clk(clk),
        .rst(rst),
        .in_valid(y_next_valid),
        .in_data(y_next),
        .out_valid(out_valid),
        .out_data(out)
    );

    // Update y[n-1].
    reg busy;
    assign in_ready = ~busy;
    always @(posedge clk) begin
        if (rst) begin
            y_1 <= {WX{1'b0}};
            busy <= 1'b0;
        end else begin
            if (y_next_valid) begin
                y_1 <= y_next;
                busy <= 1'b0;
            end else if (in_valid && in_ready) begin
                busy <= 1'b1;
            end
        end
    end
endmodule
