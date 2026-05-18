/// Combinational floating-point compare. Produces three mutually-exclusive one-hot flags.
///
/// Non-canonical zero or infinity bit patterns are still treated per spec: any exponent-zero pattern compares
/// equal to canonical +0, and infinities of the same sign compare equal regardless of input fraction bits.
/// The class-detection paths run in parallel with the wide compare so they do not extend its critical path.
///
/// Only one wide comparator is instantiated: `a < b` (carry chain) and `a == b` (XOR-reduce) share the same
/// operands and are derived independently; `a > b` is the leftover case. See zkf_cmp for a registered variant.

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

    // Build a monotonic comparison key directly from the raw bits, skipping the explicit canonicalization step.
    // Sign-magnitude to ordered-unsigned: invert all bits for negatives, force the sign bit high for non-negatives.
    // Equivalent per-bit form: msb = ~sign, magnitude_bit_i = sign XOR raw_bit_i. The transform has LUT-depth one
    // and runs in parallel with the zero/inf classification below, so the wide compare carry chain no longer waits
    // on `a_zero`/`a_inf`.
    wire [WFULL-1:0] a_key = {~a[WFULL-1], a[WFULL-2:0] ^ {(WFULL-1){a[WFULL-1]}}};
    wire [WFULL-1:0] b_key = {~b[WFULL-1], b[WFULL-2:0] ^ {(WFULL-1){b[WFULL-1]}}};

    // Class detection. Both run in parallel with the wide compare. Any exp-zero pattern decodes as +0 and any
    // exp-all-ones pattern as signed infinity, so non-canonical operands must be folded to canonical equality:
    //   - any two zeros compare equal regardless of stored sign or fraction;
    //   - two infinities with the same sign compare equal regardless of stored fraction.
    wire a_zero        = ~|a[WFULL-2:WFRAC];
    wire b_zero        = ~|b[WFULL-2:WFRAC];
    wire a_inf         =  &a[WFULL-2:WFRAC];
    wire b_inf         =  &b[WFULL-2:WFRAC];
    wire both_zero     = a_zero & b_zero;
    wire same_sign_inf = a_inf & b_inf & ~(a[WFULL-1] ^ b[WFULL-1]);
    wire override_eq   = both_zero | same_sign_inf;

    // Raw key compare. `<` and `==` are independent reductions on the same operands; `>` is the leftover case.
    wire raw_lt = a_key <  b_key;
    wire raw_eq = a_key == b_key;
    assign a_eq_b = raw_eq | override_eq;
    assign a_lt_b = raw_lt & ~override_eq;
    assign a_gt_b = ~(a_lt_b | a_eq_b);
endmodule

`default_nettype wire
