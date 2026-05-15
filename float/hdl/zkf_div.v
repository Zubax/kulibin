/// Streamed Zubax Kulibin float divider.
/// The quotient is rounded by _zkf_pack; div0 is aligned with q/out_valid.
///
/// Pipeline depth: 4+((WMAN+2+((WMAN+2)%2))/2) stages from in_valid to out_valid.

`default_nettype none

module zkf_div #(
    parameter WEXP = 6,      // exponent field width
    parameter WMAN = 18      // significand precision including the hidden bit
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

    // A single stage is needed to latch the inputs to shield the combinational paths in the div core.
    reg             s1_valid;
    reg [WFULL-1:0] s1_a;
    reg [WFULL-1:0] s1_b;

    wire                            core_valid;
    wire                            core_sign;
    wire                            core_force_zero;
    wire                            core_force_inf;
    wire signed [WEXP_UNBIASED-1:0] core_exp_unbiased;
    wire                 [WMAN-1:0] core_significand;
    wire                            core_guard;
    wire                            core_round;
    wire                            core_sticky;
    wire                            core_div0;

    _zkf_div_core #(.WEXP(WEXP), .WMAN(WMAN)) u_core (
        .clk(clk),
        .rst(rst),
        .in_valid(s1_valid),
        .a(s1_a),
        .b(s1_b),
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

    // Reset only stream validity. Payload registers intentionally free-run.
    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= in_valid;
        end
        s1_a <= a;
        s1_b <= b;
    end
endmodule

`default_nettype wire
