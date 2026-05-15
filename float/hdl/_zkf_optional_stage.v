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

            assign out_valid   = valid_q;
            assign out_payload = payload_q;

            always @(posedge clk) begin
                if (rst) begin
                    valid_q <= 1'b0;
                end else begin
                    valid_q <= in_valid;
                end
                payload_q <= in_payload;
            end
        end else begin : g_passthrough
            assign out_valid  = in_valid;
            assign out_payload = in_payload;
        end
    endgenerate
endmodule

`default_nettype wire
