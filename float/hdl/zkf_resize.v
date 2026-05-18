/// Streamed cast between two Zubax Kulibin float formats.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Register stages: same as _zkf_pack.
///
/// Widening is exact unless the output exponent range cannot represent the input value.
/// Narrowing uses round-to-nearest, ties-to-even on the discarded fraction.
/// Zero canonicalises to +0 in the output format; signed infinity stays signed infinity.
/// Out-of-range exponents map to signed infinity (overflow) or +0 (underflow).

`default_nettype none

module zkf_resize #(
    parameter WEXP_IN  = 6,
    parameter WMAN_IN  = 18,
    parameter WEXP_OUT = 5,
    parameter WMAN_OUT = 11
) (
    input wire clk,
    input wire rst,

    input wire                       in_valid,
    input wire [WEXP_IN+WMAN_IN-1:0] a,

    output wire                          out_valid,
    output wire [WEXP_OUT+WMAN_OUT-1:0]  y
);
    // verilator coverage_off
    generate
        if ((WEXP_IN < 2) || (WMAN_IN < 4) || (WEXP_OUT < 2) || (WMAN_OUT < 4)) begin : g_invalid
            _zkf_invalid_wexp_or_wman u_invalid();
        end
    endgenerate
    // verilator coverage_on

    localparam WFRAC_IN = WMAN_IN  - 1;
    localparam WFULL_IN = WEXP_IN  + WMAN_IN;
    // Output-side accumulator width for the unbiased exponent. Must hold the input format's full
    // signed exp_unbiased range (WEXP_IN + 1 signed bits) and also _zkf_pack's internal range
    // requirement of at least WEXP_OUT + 2 signed bits.
    localparam WEU_PACK_MIN = WEXP_OUT + 2;
    localparam WEU_IN_MIN   = WEXP_IN  + 1;
    localparam WEU          = (WEU_PACK_MIN > WEU_IN_MIN) ? WEU_PACK_MIN : WEU_IN_MIN;

    // Decode under the input format. Canonicalisation of zero (frac/sign ignored when exp == 0) and
    // signed infinity (frac ignored when exp == all_ones) happens here.
    wire                sign_in = a[WFULL_IN-1];
    wire [WEXP_IN-1:0]  exp_in  = a[WFULL_IN-2:WFRAC_IN];
    wire [WFRAC_IN-1:0] frac_in = a[WFRAC_IN-1:0];
    wire                is_zero = ~|exp_in;
    wire                is_inf  =  &exp_in;
    wire [WMAN_IN-1:0]  sig_in  = {1'b1, frac_in};

    // exp_unbiased = exp_in - IN_BIAS, performed as a single signed add with a folded constant so the path lands on
    // the carry chain rather than a comparator + adder. IN_BIAS is built from a sized vector (top bit 0, lower
    // WEXP_IN-1 bits all 1 = 2^(WEXP_IN-1) - 1); this keeps the constant portable for any WEXP_IN >= 2.
    localparam [WEXP_IN-1:0]    IN_BIAS      = {1'b0, {(WEXP_IN-1){1'b1}}};
    localparam signed [WEU-1:0] IN_BIAS_EXT  = $signed({{(WEU-WEXP_IN){1'b0}}, IN_BIAS});
    wire       signed [WEU-1:0] exp_unbiased = $signed({{(WEU-WEXP_IN){1'b0}}, exp_in}) - IN_BIAS_EXT;

    // Significand mapping. Decided at elaboration time so only one branch exists in the netlist.
    wire [WMAN_OUT-1:0] significand_out;
    wire                guard_out;
    wire                round_out;
    wire                sticky_out;

    generate
        if (WMAN_OUT >= WMAN_IN) begin : g_widen
            // Exact: copy the input significand and pad the new low bits with zeros.
            localparam integer PAD = WMAN_OUT - WMAN_IN;
            if (PAD == 0) begin : g_same_width
                assign significand_out = sig_in;
            end else begin : g_zero_pad
                assign significand_out = {sig_in, {PAD{1'b0}}};
            end
            assign guard_out  = 1'b0;
            assign round_out  = 1'b0;
            assign sticky_out = 1'b0;
        end else begin : g_narrow
            localparam integer DROP = WMAN_IN - WMAN_OUT;
            assign significand_out = sig_in[WMAN_IN-1 -: WMAN_OUT];
            assign guard_out       = sig_in[DROP - 1];
            if (DROP >= 2) begin : g_round_real
                assign round_out = sig_in[DROP - 2];
            end else begin : g_round_zero
                assign round_out = 1'b0;
            end
            if (DROP >= 3) begin : g_sticky_real
                assign sticky_out = |sig_in[DROP - 3 : 0];
            end else begin : g_sticky_zero
                assign sticky_out = 1'b0;
            end
        end
    endgenerate

    _zkf_pack #(.WEXP(WEXP_OUT), .WMAN(WMAN_OUT), .WEXP_UNBIASED(WEU)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .sign(sign_in),
        .force_zero(is_zero),
        .force_inf(is_inf),
        .exp_unbiased(exp_unbiased),
        .significand(significand_out),
        .guard(guard_out),
        .round(round_out),
        .sticky(sticky_out),
        .out_valid(out_valid),
        .y(y)
    );
endmodule

`default_nettype wire
