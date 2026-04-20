/// Converts a signed integer from WIN bits to WOUT bits by truncating LSbs with rounding to nearest,
/// ties to even, and saturation. If WOUT >= WIN, least-significant zero bits are added to match WOUT.
///
/// This solution is purely combinational which can be undesirable due to the potentially long critical path;
/// pipelining may be needed in that case.
///
/// One use case is the conversion of a signal sample to a narrower format. This cannot be done by simple truncation,
/// as that would bias the signal by 0.5 LSB.
///
/// https://en.wikipedia.org/wiki/Rounding#Rounding_half_to_even

`default_nettype none

module round_signed#(
    parameter WIN  = 16,
    parameter WOUT = 8
)(
    input  wire signed [WIN-1:0]  din,
    output wire signed [WOUT-1:0] dout
);
    initial if (WOUT < 2) $fatal;
    generate
        if (WOUT == WIN) begin : g_nop
            assign dout = din;
        end else if (WOUT > WIN) begin : g_extend
            assign dout = {din, {(WOUT-WIN){1'b0}}};  // zero-pad LSBs
        end else begin : g_round
            localparam integer K    = WIN - WOUT;  // K >= 1
            localparam [K-1:0] HALF = (K > 1) ? {1'b1, {(K-1){1'b0}}} : {K{1'b1}};

            // Counter-intuitively, the LSB remainder treatment is the same for positive and negative numbers.
            // Write out the truth table to see why.
            wire         neg = din[WIN-1];
            wire [K-1:0] rem = din[K-1:0];    // LSB remainder

            // The key question is whether to increment the truncated value by 1 or not.
            // This is done if the remainder requires rounding up, and the addition will not overflow the + case.
            // The negative case cannot overflow because we are adding +1 to a negative number (it may become 0).
            wire inc_need = (rem > HALF) | ((rem == HALF) & din[K]);
            wire inc_safe = neg | ~(&(din[WIN-2:K]));
            wire inc      = inc_need & inc_safe;

            // Add either 0 or 1; will not overflow but may become zero if was negative.
            assign dout = $signed(din[WIN-1:K]) + $signed({{(WOUT-1){1'b0}}, inc});
        end
    endgenerate
endmodule
