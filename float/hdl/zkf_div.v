/// Streamed Zubax Kulibin float divider.
/// The quotient is rounded by _zkf_pack; div0 is aligned with q/out_valid.
/// div0 reports that the divisor's exponent field is zero (i.e., the divisor encodes +0). It is
/// independent of the quotient: in particular div0 is also asserted for 0/0, where q = +0.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Register stages: 3+((WMAN+2+((WMAN+2)%2))/2)+STAGE_INPUT end-to-end.

`default_nettype none

module zkf_div #(
    parameter WEXP        = 6,    // exponent field width
    parameter WMAN        = 18,   // significand precision including the hidden bit
    parameter STAGE_INPUT = 0     // whether to add a stage at the input (shields inputs from combinational paths)
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,
    input wire [WEXP+WMAN-1:0] b,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] q,
    output wire                 div0
);
    localparam WFULL         = WEXP + WMAN;
    localparam WEXP_UNBIASED = WEXP + 2;

    // Optional input register stage. The divider's pipeline depth already scales with operand width, so
    // a single extra stage is the only useful setting; anything beyond that is silently clamped to 1.
    wire                in_valid_q;
    wire [2*WFULL-1:0]  pipe_out;
    _zkf_pipe #(.W(2*WFULL), .N(STAGE_INPUT ? 1 : 0)) u_input_pipe (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in({b, a}), .out_valid(in_valid_q), .out(pipe_out)
    );
    wire [WFULL-1:0] a_q = pipe_out[WFULL-1:0];
    wire [WFULL-1:0] b_q = pipe_out[2*WFULL-1:WFULL];

    wire                            core_valid;
    wire                            core_sign;
    wire                            core_force_zero;
    wire                            core_force_inf;
    wire signed [WEXP_UNBIASED-1:0] core_exp_unbiased;
    // normalized quotient significand; its hidden-bit MSB is structurally 1.
    // verilator coverage_off
    wire                 [WMAN-1:0] core_significand;
    // verilator coverage_on
    wire                            core_guard;
    wire                            core_round;
    wire                            core_sticky;
    wire                            core_div0;

    _zkf_div_core #(.WEXP(WEXP), .WMAN(WMAN)) u_core (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid_q),
        .a(a_q),
        .b(b_q),
        .out_valid(core_valid),
        .sign(core_sign),
        .force_zero(core_force_zero),
        .force_inf(core_force_inf),
        .exp_unbiased(core_exp_unbiased),
        .significand(core_significand),
        .guard(core_guard),
        .round(core_round),
        .sticky(core_sticky),
        .div0(core_div0),
        .partial_rem()  // Partial remainder is not used in this module.
    );

    // The packer has registered outputs, so it is safe to connect it to the external signals directly.
    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(core_valid),
        .sign(core_sign),
        .force_zero(core_force_zero),
        .force_inf(core_force_inf),
        .exp_unbiased(core_exp_unbiased),
        .significand(core_significand),
        .guard(core_guard),
        .round(core_round),
        .sticky(core_sticky),
        .out_valid(out_valid),
        .y(q)
    );

    // The delay line needs no reset since it doesn't carry control signals. See reset policy.
    _zkf_pack_delay#(.W(1)) u_pack_delay(.clk(clk), .rst(1'b0), .x(core_div0), .y(div0));
endmodule

`default_nettype wire
