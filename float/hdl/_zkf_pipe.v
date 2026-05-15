/// A set of N register stages, each W bits wide. If N=0 (default), acts as a no-op passthrough, clk/rst unused/ignored.

`default_nettype none

module _zkf_pipe #(parameter W = 1, parameter N = 0) (
    input wire clk,
    input wire rst,

    input wire         in_valid,
    input wire [W-1:0] in,

    output wire         out_valid,
    output wire [W-1:0] out
);
    generate
        if (N) begin : g_registered
            reg [N-1:0] valid_pipe;
            reg [W-1:0] data_pipe [0:N-1];

            integer i;
            always @(posedge clk) begin
                if (rst) begin  // Reset only stream validity. Payload registers intentionally free-run.
                    valid_pipe <= {N{1'b0}};
                end else begin
                    valid_pipe[0] <= in_valid;
                    data_pipe[0]  <= in;
                    for (i = 1; i < N; i = i + 1) begin
                        valid_pipe[i] <= valid_pipe[i-1];
                        data_pipe[i]  <= data_pipe[i-1];
                    end
                end
            end
            assign out_valid = valid_pipe[N-1];
            assign out       = data_pipe[N-1];

        end else begin : g_passthrough
            assign out_valid = in_valid;
            assign out       = in;
        end
    endgenerate
endmodule

`default_nettype wire
