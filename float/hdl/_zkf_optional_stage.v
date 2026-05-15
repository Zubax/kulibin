/// A single register stage if ENABLE=1; otherwise no-op passthrough.

`default_nettype none

module _zkf_optional_stage #(parameter W = 1, parameter ENABLE = 0) (
    input wire clk,
    input wire rst,

    input wire         in_valid,
    input wire [W-1:0] in,

    output wire         out_valid,
    output wire [W-1:0] out
);
    generate
        if (ENABLE) begin : g_registered
            reg         valid_q;
            reg [W-1:0] payload_q;

            assign out_valid = valid_q;
            assign out       = payload_q;

            always @(posedge clk) begin
                if (rst) valid_q <= 1'b0;
                else     valid_q <= in_valid;
                payload_q <= in;
            end
        end else begin : g_passthrough
            assign out_valid = in_valid;
            assign out       = in;
        end
    endgenerate
endmodule

`default_nettype wire
