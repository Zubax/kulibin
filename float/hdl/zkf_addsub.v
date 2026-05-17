/// Streamed Zubax Kulibin float adder/subtractor.
/// y = a + b when op_sub == 0; y = a - b when op_sub == 1.
/// Register stages: same as zkf_add.

`default_nettype none

module zkf_addsub #(
    parameter WEXP = 6,      // exponent field width
    parameter WMAN = 18      // significand precision including the hidden bit
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,
    input wire                 op_sub,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y
);
    localparam WFULL = WEXP + WMAN;
    zkf_add #(.WEXP(WEXP), .WMAN(WMAN)) u_add (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .a(a),
        .b({b[WFULL-1] ^ op_sub, b[WFULL-2:0]}),
        .out_valid(out_valid),
        .y(y)
    );
endmodule

`default_nettype wire
