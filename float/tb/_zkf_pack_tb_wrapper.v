`default_nettype none

module _zkf_pack_tb_wrapper #(
    parameter WEXP = 6,
    parameter WMAN = 18,
    parameter WMAG = 2 * WMAN,
    parameter WSCALE = 1,
    parameter WLOG = (WMAG <= 2) ? 1 : $clog2(WMAG)
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

    _zkf_pack #(
        .WEXP(WEXP),
        .WMAN(WMAN),
        .WMAG(WMAG),
        .WSCALE(WSCALE),
        .WLOG(WLOG)
    ) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .sign(sign),
        .mag(mag),
        .mag_zero(mag_zero),
        .mag_flog2(mag_flog2),
        .scale(scale),
        .out_valid(out_valid),
        .y(y)
    );
endmodule

`default_nettype wire
