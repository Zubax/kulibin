/// Combinational saturation. If x is finite, returns x as-is. If x is signed infinity,
/// returns the largest representable finite value with the same sign.

`default_nettype none

module zkf_saturate #(parameter WEXP = 6, parameter WMAN = 18) (
    input  wire [WEXP+WMAN-1:0] x,
    output wire [WEXP+WMAN-1:0] y
);
    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;

    wire             x_inf = &x[WFULL-2:WFRAC];
    // verilator coverage_off
    // Constant max-finite encoding: only the sign bit (copied from x) varies; the exponent/fraction
    // fields are compile-time constant. The selected output y stays covered.
    wire [WFULL-1:0] sat   = {x[WFULL-1], {WEXP-1{1'b1}}, 1'b0, {WFRAC{1'b1}}};
    // verilator coverage_on

    assign y = x_inf ? sat : x;
endmodule

`default_nettype wire
