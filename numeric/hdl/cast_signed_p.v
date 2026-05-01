/// A trivial pipelined alternative for cast_signed that adds 1 or 2 register stages, one of which is at the output.
/// The number of stages depends on the parameters.
///
/// It is assumed that the external circuit connected to the inputs has a relatively short critical path,
/// which appears to be the case in typical scenarios, since placing registers at the output is
/// advantageous for P&R compared to the opposite scenario where the input registers are added.
///
/// The synthesis tool is expected to redistribute the registers via retiming as needed.
///
///                0   1   2   3
///             ─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐
/// clk=         └─┘ └─┘ └─┘ └─┘ └
///              ┌───┐
/// in_valid=   ─┘   └────────────
///                  ┌───┐
/// out_valid=  ─────┘   └────────     single-stage operation
///                      ┌───┐
/// out_valid=  ─────────┘   └────     two-stage operation

module cast_signed_p#(
    // Refer to the non-pipelined cast_signed for the parameter description.
    parameter WIN = 16,
    parameter signed MSB = 0,
    parameter signed LSB = 0,
    parameter TWO_STAGE = (MSB > 0) && (LSB > 0)  // Force to 1 if more retiming freedom is needed with MSB=LSB=0.
)(
    input wire clk,
    input wire rst,
    // Input.
    input wire                  in_valid,
    input wire signed [WIN-1:0] in_data,
    // Output. The data remains stable between valid pulses.
    output reg                          out_valid,
    output reg signed [WIN-MSB-LSB-1:0] out_data
);
    localparam WSAT = WIN - MSB;
    localparam WOUT = WIN - MSB - LSB;
    generate
        if (TWO_STAGE) begin : g_both
            reg s1_valid;
            reg signed [WSAT-1:0] s1_data;

            wire signed [WSAT-1:0] dsat;
            wire signed [WOUT-1:0] dout;
            saturate_signed #(.WIN(WIN),  .WOUT(WSAT)) sat (.din(in_data), .dout(dsat));
            round_signed    #(.WIN(WSAT), .WOUT(WOUT)) rnd (.din(s1_data), .dout(dout));

            always @(posedge clk) begin
                if (rst) begin
                    s1_valid <= 1'b0;
                    s1_data  <= {WSAT{1'b0}};
                    out_valid <= 1'b0;
                    out_data <= {WOUT{1'b0}};
                end else begin
                    if (in_valid) begin
                        s1_valid <= 1'b1;
                        s1_data  <= dsat;
                    end else if (s1_valid) begin
                        s1_valid <= 1'b0;
                    end

                    if (s1_valid) begin
                        out_valid <= 1'b1;
                        out_data  <= dout;
                    end else if (out_valid) begin
                        out_valid <= 1'b0;
                    end
                end
            end
        end else begin : g_single
            // Squeeze both into a single stage because one or both of the operations are no-ops.
            wire signed [WSAT-1:0] dsat;
            wire signed [WOUT-1:0] dout;
            saturate_signed #(.WIN(WIN),  .WOUT(WSAT)) sat (.din(in_data), .dout(dsat));
            round_signed    #(.WIN(WSAT), .WOUT(WOUT)) rnd (.din(dsat),    .dout(dout));

            always @(posedge clk) begin
                if (rst) begin
                    out_valid <= 1'b0;
                    out_data <= {WOUT{1'b0}};
                end else begin
                    if (in_valid) begin
                        out_valid <= 1'b1;
                        out_data  <= dout;
                    end else if (out_valid) begin
                        out_valid <= 1'b0;
                    end
                end
            end
        end
    endgenerate
endmodule
