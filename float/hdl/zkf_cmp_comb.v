/// Combinational floating-point compare. Produces three mutually-exclusive one-hot flags.
///
/// Inputs are canonicalized prior to comparison so non-canonical zero or infinity bit patterns behave per spec:
/// any exponent-zero pattern compares equal to canonical +0, and infinities of the same sign compare equal
/// regardless of input fraction bits.
///
/// The combinational path is non-trivial (canonicalization, monotonic-key transform, WFULL-wide compare);
/// see zkf_cmp for a registered variant when this depth matters for timing.

`default_nettype none

module zkf_cmp_comb #(parameter WEXP = 6, parameter WMAN = 18) (
    input  wire [WEXP+WMAN-1:0] a,
    input  wire [WEXP+WMAN-1:0] b,

    output wire a_gt_b, // a > b
    output wire a_eq_b, // a = b
    output wire a_lt_b  // a < b
);
    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;

    // Class detection. Exponent zero decodes as +0 with sign and fraction ignored.
    // Exponent all-ones decodes as signed infinity with fraction ignored.
    wire a_zero = ~|a[WFULL-2:WFRAC];
    wire b_zero = ~|b[WFULL-2:WFRAC];
    wire a_inf  =  &a[WFULL-2:WFRAC];
    wire b_inf  =  &b[WFULL-2:WFRAC];

    wire             a_sign  = a[WFULL-1] & ~a_zero;
    wire             b_sign  = b[WFULL-1] & ~b_zero;
    wire [WFRAC-1:0] a_frac  = (a_zero | a_inf) ? {WFRAC{1'b0}} : a[WFRAC-1:0];
    wire [WFRAC-1:0] b_frac  = (b_zero | b_inf) ? {WFRAC{1'b0}} : b[WFRAC-1:0];
    wire [WFULL-1:0] a_canon = {a_sign, a[WFULL-2:WFRAC], a_frac};
    wire [WFULL-1:0] b_canon = {b_sign, b[WFULL-2:WFRAC], b_frac};

    // Sign-magnitude to ordered-unsigned key: invert all bits for negatives, set the sign bit to 1 for non-negatives.
    // Unsigned compare of the keys matches signed float ordering across the full range including infinities.
    wire [WFULL-1:0] a_key = a_canon[WFULL-1] ? ~a_canon : (a_canon | {1'b1, {WFULL-1{1'b0}}});
    wire [WFULL-1:0] b_key = b_canon[WFULL-1] ? ~b_canon : (b_canon | {1'b1, {WFULL-1{1'b0}}});

    assign a_gt_b = a_key >  b_key;
    assign a_eq_b = a_key == b_key;
    assign a_lt_b = a_key <  b_key;
endmodule

`default_nettype wire
