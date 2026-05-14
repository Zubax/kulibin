`default_nettype none

module _zkf_pack_tb_wrapper #(
    parameter WEXP = 6,
    parameter WMAN = 18,
    parameter WMAG = 2 * WMAN,
    parameter WSCALE = 1,
    parameter WLOG = (WMAG <= 2) ? 1 : $clog2(WMAG),
    parameter WEXP_WORK_A = (WSCALE > WLOG) ? WSCALE : WLOG,
    parameter WEXP_WORK_B = (WEXP_WORK_A > WEXP) ? WEXP_WORK_A : WEXP,
    parameter WEXP_UNBIASED = WEXP_WORK_B + 2
)(
    input  wire clk,
    input  wire rst,

    input  wire                     in_valid,
    input  wire                     sign,
    input  wire          [WMAG-1:0] mag,
    input  wire signed [WSCALE-1:0] scale,

    output wire                  out_valid,
    output wire [WEXP+WMAN-1:0]  y
);
    wire mag_zero;
    wire [WLOG-1:0] mag_flog2;

    _zkf_ilog2_floor #(.W(WMAG), .WINDEX(WLOG)) u_ilog2_floor (.x(mag), .zero(mag_zero), .y(mag_flog2));

    wire signed [WEXP_UNBIASED-1:0] scale_ext = {{(WEXP_UNBIASED-WSCALE){scale[WSCALE-1]}}, scale};
    wire signed [WEXP_UNBIASED-1:0] log2_ext  = {{(WEXP_UNBIASED-WLOG){1'b0}}, mag_flog2};
    wire signed [WEXP_UNBIASED-1:0] exp_unbiased = scale_ext + log2_ext;

    localparam WALIGN = WMAG + WMAN + 1;
    wire [WALIGN-1:0] aligned     = {mag, {WMAN+1{1'b0}}} >> mag_flog2;
    wire   [WMAN-1:0] significand = aligned[WMAN+1:2];
    wire              guard       = aligned[1];
    wire              round       = aligned[0];

    wire [WMAG-1:0] sticky_bits;
    genvar i_sticky;
    generate
        for (i_sticky = 0; i_sticky < WMAG; i_sticky = i_sticky + 1) begin : g_sticky
            if ((i_sticky + WMAN + 2) < WMAG) begin : g_used
                localparam [WLOG-1:0] THRESHOLD = i_sticky + WMAN + 2;
                assign sticky_bits[i_sticky] = mag[i_sticky] && (mag_flog2 >= THRESHOLD);
            end else begin : g_unused
                assign sticky_bits[i_sticky] = 1'b0;
            end
        end
    endgenerate
    wire sticky = |sticky_bits;

    _zkf_pack #(
        .WEXP(WEXP),
        .WMAN(WMAN),
        .WEXP_UNBIASED(WEXP_UNBIASED)
    ) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .sign(sign),
        .force_zero(mag_zero),
        .force_inf(1'b0),
        .exp_unbiased(exp_unbiased),
        .significand(significand),
        .guard(guard),
        .round(round),
        .sticky(sticky),
        .out_valid(out_valid),
        .y(y)
    );
endmodule

`default_nettype wire
