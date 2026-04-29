/// Anti-metastability synchronizer / input delay line.
/// Each of the WIDTH input bits is passed through an independent chain of DEPTH cascaded flip-flops.
///
/// Multi-bit synchronization (WIDTH > 1) is only safe when the source bus is either Gray-coded or stable
/// for at least DEPTH+1 cycles around any sampling event. The module makes no attempt to coordinate bits
/// across the WIDTH dimension.

module cdc_sync #(
    parameter WIDTH = 1,    ///< Number of independent bits to synchronize. Each gets its own chain.
    parameter DEPTH = 2     ///< Number of flip-flop stages per chain. Should be at least 2.
)(
    input  wire             clk,
    input  wire             rst,
    input  wire [WIDTH-1:0] in,
    output wire [WIDTH-1:0] out
);
    genvar g_idx;
    generate
        for (g_idx = 0; g_idx < WIDTH; g_idx = g_idx + 1) begin : g_chain
            (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO", syn_preserve = 1, syn_keep = 1 *)
            reg [DEPTH-1:0] ff;
            always @(posedge clk) begin
                if (rst) ff <= {DEPTH{1'b0}};
                else     ff <= {ff[DEPTH-2:0], in[g_idx]};
            end
            assign out[g_idx] = ff[DEPTH-1];
        end
    endgenerate
endmodule
