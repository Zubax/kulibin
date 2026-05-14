/// Streamed Zubax Kulibin float divider.
/// The quotient is rounded by _zkf_pack; div0 is aligned with q/out_valid.
///
/// Pipeline depth: WMAN+8+((WMAN+4)%2) stages from in_valid to out_valid:
/// one public input latch, _zkf_div_core, and _zkf_pack with two stages.

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
    localparam WFULL       = WEXP + WMAN;
    localparam QFRAC_BASE  = WMAN + 4;
    localparam QFRAC       = QFRAC_BASE + (QFRAC_BASE % 2);
    localparam QWMAG       = QFRAC + 2;
    localparam QWLOG       = $clog2(QWMAG);
    localparam WQFRAC_BITS = $clog2(QFRAC + 2);
    localparam WSCALE_BASE = (WEXP > WQFRAC_BITS) ? WEXP : WQFRAC_BITS;
    localparam WSCALE      = WSCALE_BASE + 2;

    // A single stage is needed to latch the inputs to shield the combinational paths in the div core.
    reg             s1_valid;
    reg [WFULL-1:0] s1_a;
    reg [WFULL-1:0] s1_b;

    wire                     core_valid;
    wire                     core_sign;
    wire         [QWMAG-1:0] core_mag;
    wire                     core_mag_zero;
    wire         [QWLOG-1:0] core_mag_flog2;
    wire signed [WSCALE-1:0] core_scale;
    wire                     core_div0;

    _zkf_div_core #(.WEXP(WEXP), .WMAN(WMAN)) u_core (
        .clk(clk),
        .rst(rst),
        .in_valid(s1_valid),
        .a(s1_a),
        .b(s1_b),
        .out_valid(core_valid),
        .sign(core_sign),
        .mag(core_mag),
        .mag_zero(core_mag_zero),
        .mag_flog2(core_mag_flog2),
        .scale(core_scale),
        .div0(core_div0),
        .partial_rem()  // Partial reminder is not used in this module.
    );

    // The packer has registered outputs, so it is safe to connect it to the external signals directly.
    // Its inputs are also registered so the combinational outputs of the div core terminate there cleanly.
    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WMAG(QWMAG), .WSCALE(WSCALE), .WLOG(QWLOG)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(core_valid),
        .sign(core_sign),
        .mag(core_mag),
        .mag_zero(core_mag_zero),
        .mag_flog2(core_mag_flog2),
        .scale(core_scale),
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
