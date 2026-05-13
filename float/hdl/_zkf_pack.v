/// Pack an exact scaled unsigned integer magnitude into Zubax Kulibin float with saturation and rounding to nearest.
/// The exact input value is:
///
///     (-1)^sign * mag * 2^scale
///
/// The output is canonical zero for zero/underflow, round-to-nearest ties-to-even for normal values,
/// and signed saturation for exponent overflow.

module _zkf_pack #(
    parameter WEXP = 8,              // exponent field width
    parameter WMAN = 16,             // significand precision including the hidden bit
    parameter WMAG = 2 * WMAN,       // input magnitude width; usually set by the instantiator
    parameter WSCALE = 1             // signed binary scale width; always set by the instantiator depending on usage
)(
    input  wire clk,
    input  wire rst,

    input  wire                     in_valid,
    input  wire                     sign,
    input  wire          [WMAG-1:0] mag,
    input  wire signed [WSCALE-1:0] scale,

    output reg                   out_valid,
    output reg  [WEXP+WMAN-1:0]  y,
    output reg                   saturated
);
    // TODO: implement.
endmodule
