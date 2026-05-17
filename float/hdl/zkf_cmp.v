/// Streamed floating-point compare.
/// Equivalent to zkf_cmp_comb with just a single pipeline stage.
/// Register stages: 1.

`default_nettype none

module zkf_cmp #(
    parameter WEXP = 6,
    parameter WMAN = 18
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,

    output reg out_valid,
    output reg a_gt_b,      // a > b
    output reg a_eq_b,      // a = b
    output reg a_lt_b       // a < b
);
    wire c_a_gt_b;
    wire c_a_eq_b;
    wire c_a_lt_b;

    zkf_cmp_comb #(.WEXP(WEXP), .WMAN(WMAN)) u_cmp (
        .a(a),
        .b(b),
        .a_gt_b(c_a_gt_b),
        .a_eq_b(c_a_eq_b),
        .a_lt_b(c_a_lt_b)
    );

    // Reset only stream validity. Payload registers intentionally free-run.
    always @(posedge clk) begin
        if (rst) out_valid <= 1'b0;
        else     out_valid <= in_valid;
        a_gt_b <= c_a_gt_b;
        a_eq_b <= c_a_eq_b;
        a_lt_b <= c_a_lt_b;
    end
endmodule

`default_nettype wire
