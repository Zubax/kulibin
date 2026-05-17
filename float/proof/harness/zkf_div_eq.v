/// Formal harness: zkf_div DUT vs zkf_div_ref.
/// Pipeline depth = 4 + ((WMAN+2+((WMAN+2)%2))/2). For WMAN=6: QFRAC=8, QSTAGES=4, total=8. For WMAN=4: 4+3=7.

`default_nettype none

module zkf_div_eq #(parameter WEXP = 4, parameter WMAN = 6) (
    input wire clk,
    input wire rst,
    input wire in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b
);
    localparam WFULL       = WEXP + WMAN;
    localparam QFRAC_BASE  = WMAN + 2;
    localparam QFRAC       = QFRAC_BASE + (QFRAC_BASE % 2);
    localparam QSTAGES     = QFRAC / 2;
    localparam PIPE_STAGES = 4 + QSTAGES;
    localparam T_RESULT    = 1 + PIPE_STAGES;
    localparam CYCLE_W     = 6;

    reg [CYCLE_W-1:0] cycle = {CYCLE_W{1'b0}};
    always @(posedge clk) cycle <= (cycle == {CYCLE_W{1'b1}}) ? cycle : cycle + 1'b1;

    always @(*) begin
        if (cycle == 0) begin
            assume(rst == 1'b1);
            assume(in_valid == 1'b0);
        end else if (cycle == 1) begin
            assume(rst == 1'b0);
            assume(in_valid == 1'b1);
        end else begin
            assume(rst == 1'b0);
            assume(in_valid == 1'b0);
        end
    end

    reg [WFULL-1:0] a_shadow, b_shadow;
    always @(posedge clk) if (cycle == 1) begin
        a_shadow <= a;
        b_shadow <= b;
    end

    wire             dut_valid;
    wire [WFULL-1:0] dut_q;
    wire             dut_div0;
    zkf_div #(.WEXP(WEXP), .WMAN(WMAN)) u_dut (
        .clk(clk), .rst(rst), .in_valid(in_valid),
        .a(a), .b(b),
        .out_valid(dut_valid), .q(dut_q), .div0(dut_div0)
    );

    wire [WFULL-1:0] ref_q;
    wire             ref_div0;
    zkf_div_ref #(.WEXP(WEXP), .WMAN(WMAN)) u_ref (
        .a(a_shadow), .b(b_shadow),
        .q(ref_q), .div0(ref_div0)
    );

    always @(posedge clk) begin
        if (cycle == T_RESULT) begin
            assert(dut_valid == 1'b1);
            assert(dut_q == ref_q);
            assert(dut_div0 == ref_div0);
        end
        if (cycle >= 1 && cycle < T_RESULT) assert(dut_valid == 1'b0);
    end
endmodule

`default_nettype wire
