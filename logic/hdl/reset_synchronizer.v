/// Async active-high reset with synchronized deassertion to avoid metastability.
/// This is intended for gating a global external async reset signal to the local clock domain.

module reset_synchronizer#(
    /// The number of synchronous reset outputs.
    /// Each synchronous output has its own dedicated delay line with asynchronous reset,
    /// which allows the mapper to place them arbitrarily without regard for the combinational path length.
    parameter FANOUT = 1,

    /// The length of the delay line and the minimum duration of the synchronous reset pulse output in clock cycles.
    /// Shall be at least 2, no upper limit.
    parameter DELAY = 3
)(
    input wire clk,
    input wire arst,
    output wire [FANOUT-1:0] rst
);
    genvar g_idx;
    generate
        for (g_idx = 0; g_idx < FANOUT; g_idx = g_idx + 1) begin
            (* ASYNC_REG = "TRUE", SHREG_EXTRACT="NO" *)
            reg [DELAY-1:0] ff /* synthesis syn_async_reg=1 */;
            always @(posedge clk or posedge arst) begin
                if (arst)             ff <= {DELAY{1'b1}};
                else if (ff[DELAY-1]) ff <= {ff[DELAY-2:0], 1'b0};
            end
            assign rst[g_idx] = ff[DELAY-1];
        end
    endgenerate
endmodule
