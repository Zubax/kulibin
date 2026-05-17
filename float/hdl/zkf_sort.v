/// Streamed min/max sorter built on zkf_cmp_comb.
/// Inherits the canonical-zero and same-sign-infinity equality semantics from zkf_cmp_comb.
/// Register stages: 1.

`default_nettype none

module zkf_sort #(
    parameter WEXP = 6,
    parameter WMAN = 18
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,

    output reg                 out_valid,
    output reg [WEXP+WMAN-1:0] min,         // min(a,b)
    output reg [WEXP+WMAN-1:0] max          // max(a,b)
);
    wire a_gt_b;
    wire a_eq_b;
    wire a_lt_b;

    zkf_cmp_comb #(.WEXP(WEXP), .WMAN(WMAN)) u_cmp (
        .a(a),
        .b(b),
        .a_gt_b(a_gt_b),
        .a_eq_b(a_eq_b),
        .a_lt_b(a_lt_b)
    );

    // Reset only stream validity. Payload registers intentionally free-run.
    always @(posedge clk) begin
        if (rst) out_valid <= 1'b0;
        else     out_valid <= in_valid;
        min <= a_lt_b ? a : b;
        max <= a_lt_b ? b : a;
    end
endmodule

`default_nettype wire
