/// Given an WIN-bit signed input, truncates MSB most significant bits with saturation if the value exceeds the range
/// representable by (WIN-MSB) bits; then truncates LSB least significant bits, rounding to nearest, ties to even.
/// If MSB is negative, the value is sign-extended; if LSB is negative, the value is right-zero-padded.
/// MSB=0 or LSB=0 results in a pure no-op which is completely optimized away by synthesis tools.
///
/// One application is in CIC decimators, whose gain is R^N; the signed output is [-R^N, +R^N] assuming unity input.
/// The decimation factor R is often a power of two, which means that R^N is also a power of two.
/// As a result, the most significant bit of the output is only used if the output is at the maximum positive value,
/// which is a very rare event. We can remove that bit by saturating R^N to R^N-1. This introduces the worst-case
/// error of 1 LSB only if the dynamic range is depleted, which is negligible in most applications.
///
/// Another application is in fixed-point multiplication, where it is required to fetch the
/// middle bits of the intermediate result with correct rounding.
///
/// For example, given a 0b0001_1010 input with MSB = 2 and LSB = 2, the saturated value is 0b01_1010 (no saturation),
/// and the value after rounding is 0b0110.

module cast_signed#(parameter WIN = 16, parameter signed MSB = 0, parameter signed LSB = 0)(
    input  wire signed [WIN-1:0]         din,
    output wire signed [WIN-MSB-LSB-1:0] dout
);
    wire signed [WIN-MSB-1:0] dsat;
    saturate_signed #(.WIN(WIN),     .WOUT(WIN-MSB))     sat (.din(din),  .dout(dsat));
    round_signed    #(.WIN(WIN-MSB), .WOUT(WIN-MSB-LSB)) rnd (.din(dsat), .dout(dout));
endmodule
