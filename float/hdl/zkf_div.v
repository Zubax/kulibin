/// Streamed Zubax Kulibin float divider.
/// The quotient is rounded by _zkf_pack; div0 is aligned with q/out_valid.

`default_nettype none

module zkf_div #(
    parameter WEXP = 6,      // exponent field width
    parameter WMAN = 18      // significand precision including the hidden bit
) (
    input  wire clk,
    input  wire rst,

    input  wire                 in_valid,
    input  wire [WEXP+WMAN-1:0] a,
    input  wire [WEXP+WMAN-1:0] b,

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
    wire          [WMAN-1:0] core_partial_rem;

    reg                        pack_valid;
    reg                        pack_sign;
    (* keep *) reg [QWMAG-1:0] pack_mag;
    reg                        pack_mag_zero;
    reg            [QWLOG-1:0] pack_mag_flog2;
    reg signed    [WSCALE-1:0] pack_scale;
    reg                        pack_div0;
    reg                        pack_div0_s1;
    reg                        pack_div0_s2;
    reg                        pack_div0_s3;

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
        .partial_rem(core_partial_rem)
    );
    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WMAG(QWMAG), .WSCALE(WSCALE), .WLOG(QWLOG)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(pack_valid),
        .sign(pack_sign),
        .mag(pack_mag),
        .mag_zero(pack_mag_zero),
        .mag_flog2(pack_mag_flog2),
        .scale(pack_scale),
        .out_valid(out_valid),
        .y(q)
    );
    assign div0 = pack_div0_s3;

    // Reset only stream validity. Payload registers intentionally free-run.
    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            pack_valid <= 1'b0;
        end else begin
            s1_valid <= in_valid;
            pack_valid <= core_valid;
        end

        s1_a <= a;
        s1_b <= b;

        pack_sign <= core_sign;
        pack_mag <= core_mag;
        pack_mag_zero <= core_mag_zero;
        pack_mag_flog2 <= core_mag_flog2;
        pack_scale <= core_scale;
        pack_div0 <= core_div0;

        pack_div0_s1 <= pack_div0;
        pack_div0_s2 <= pack_div0_s1;
        pack_div0_s3 <= pack_div0_s2;
    end
endmodule

`default_nettype wire
