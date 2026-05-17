/// Formal harness: _zkf_pack DUT (2-stage) vs zkf_pack_ref.
/// Single-pulse: drive arbitrary inputs at cycle 1 with rst=0/in_valid=1, else in_valid=0.
/// Latch inputs into shadow registers at cycle 1; assert output at cycle 3.

`default_nettype none

module zkf_pack_eq #(parameter WEXP = 6, parameter WMAN = 18, parameter WEXP_UNBIASED = WEXP + 2) (
    input wire clk,
    input wire rst,
    input wire in_valid,
    input wire                            sign,
    input wire                            force_zero,
    input wire                            force_inf,
    input wire signed [WEXP_UNBIASED-1:0] exp_unbiased,
    input wire                 [WMAN-1:0] significand,
    input wire                            guard,
    input wire                            round_bit,
    input wire                            sticky
);
    localparam WFULL    = WEXP + WMAN;
    localparam T_RESULT = 3;     // 2 stage pipeline → result at cycle 1+2 = 3

    reg [3:0] cycle = 4'd0;
    always @(posedge clk) cycle <= (cycle == 4'd15) ? cycle : cycle + 4'd1;

    always @(*) begin
        if (cycle == 4'd0) begin
            assume(rst == 1'b1);
            assume(in_valid == 1'b0);
        end else if (cycle == 4'd1) begin
            assume(rst == 1'b0);
            assume(in_valid == 1'b1);
        end else begin
            assume(rst == 1'b0);
            assume(in_valid == 1'b0);
        end
    end

    // Shadow latches.
    reg                            sh_sign;
    reg                            sh_force_zero;
    reg                            sh_force_inf;
    reg signed [WEXP_UNBIASED-1:0] sh_exp_unbiased;
    reg                 [WMAN-1:0] sh_significand;
    reg                            sh_guard;
    reg                            sh_round_bit;
    reg                            sh_sticky;
    always @(posedge clk) if (cycle == 4'd1) begin
        sh_sign         <= sign;
        sh_force_zero   <= force_zero;
        sh_force_inf    <= force_inf;
        sh_exp_unbiased <= exp_unbiased;
        sh_significand  <= significand;
        sh_guard        <= guard;
        sh_round_bit    <= round_bit;
        sh_sticky       <= sticky;
    end

    // DUT.
    wire             dut_valid;
    wire [WFULL-1:0] dut_y;
    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEXP_UNBIASED)) u_dut (
        .clk(clk), .rst(rst), .in_valid(in_valid),
        .sign(sign), .force_zero(force_zero), .force_inf(force_inf),
        .exp_unbiased(exp_unbiased), .significand(significand),
        .guard(guard), .round(round_bit), .sticky(sticky),
        .out_valid(dut_valid), .y(dut_y)
    );

    // Reference.
    wire [WFULL-1:0] ref_y;
    zkf_pack_ref #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEXP_UNBIASED)) u_ref (
        .sign(sh_sign), .force_zero(sh_force_zero), .force_inf(sh_force_inf),
        .exp_unbiased(sh_exp_unbiased), .significand(sh_significand),
        .guard(sh_guard), .round_bit(sh_round_bit), .sticky(sh_sticky),
        .y(ref_y)
    );

    always @(posedge clk) begin
        if (cycle == T_RESULT) begin
            assert(dut_valid == 1'b1);
            assert(dut_y == ref_y);
        end
        if (cycle == 4'd1 || cycle == 4'd2) assert(dut_valid == 1'b0);
    end
endmodule

`default_nettype wire
