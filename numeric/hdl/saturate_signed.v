/// Given an WIN-bit signed input, truncates the most significant bits to produce a WOUT-bit signed output,
/// saturating to the maximum or minimum representable value if the input is out of range.
/// If WOUT >= WIN, the value is sign-extended.
/// The logic is purely combinational.
///
/// For example, given WOUT=16, +37268 => +32767.
///
/// One application is in CIC decimators, whose gain is R^N; the signed output is [-R^N, +R^N] assuming unity input.
/// The decimation factor R is often a power of two, which means that R^N is also a power of two.
/// As a result, the most significant bit of the output is only used if the output is at the maximum positive value,
/// which is a very rare event. We can remove that bit by saturating R^N to R^N-1. This introduces the worst-case
/// error of 1 LSB only if the dynamic range is depleted, which is negligible in most applications.

module saturate_signed#(
    parameter WIN  = 16,
    parameter WOUT = 8
)(
    input wire signed [WIN-1:0]  din,
    output reg signed [WOUT-1:0] dout
);
    initial if (WOUT < 2) $fatal;
    initial if (WIN < 2) $fatal;
    generate
        if (WOUT == WIN) begin : g_nop
            always @(*) dout = din;
        end else if (WOUT > WIN) begin : g_extend
            always @(*) dout = {{(WOUT-WIN){din[WIN-1]}}, din};
        end else begin : g_saturate
            // Output-precision rails.
            localparam signed [WOUT-1:0] SAT_POS = {1'b0, {(WOUT-1){1'b1}}};
            localparam signed [WOUT-1:0] SAT_NEG = {1'b1, {(WOUT-1){1'b0}}};

            // Same but extended to input precision for comparison.
            // DANGER: do not replace the wires with localparams, as that causes incorrect synthesis!
            // See https://stackoverflow.com/q/79769496/1007777
            wire signed [WIN-1:0] LIM_POS =  { {(WIN-(WOUT-1)){1'b0}}, {(WOUT-1){1'b1}} };
            wire signed [WIN-1:0] LIM_NEG = -$signed(LIM_POS) - 1;

            always @(*) begin
                case ({din > LIM_POS, din < LIM_NEG})
                    2'b10:   dout = SAT_POS;
                    2'b01:   dout = SAT_NEG;
                    default: dout = din[WOUT-1:0];
                endcase
            end
        end
    endgenerate
endmodule
