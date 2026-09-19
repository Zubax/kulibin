// A CIC decimator whose integrator bank is shared by KCOMB comb channels. Each channel is latched by its own decimate
// input and outputs every order 1..N (sinc^1..sinc^N); outputs left unconnected are pruned by synthesis together with
// their comb stages. The differential delay is M=1.
//
// Therefore, for the same PDM input stream, KCOMB times N outputs are produced, all N orders of one of the K combs
// are decimated simultaneously; the outputs are latched and stay stable between decimation updates:
//
//
//      shared input   shared integrators         K independent combs, each order 1 to N inclusive
//
//                     |integrator 0   |      comb 0   sinc^1     comb 0   sinc^...   comb 0   sinc^N
//      ---[input]---> |integrator ... | ---> comb ... sinc^1     comb ... sinc^...   comb ... sinc^N
//                     |integrator N-1 |      comb K-1 sinc^1     comb K-1 sinc^...   comb K-1 sinc^N
//
//
// Example: a one-bit stream decimated by 64, read as sinc^3 and sinc^2 at the tick and as sinc^2 at the half tick:
//
//     cic_decimator_multi #(.WIN(1), .RMAX(64), .N(3), .KCOMB(2)) ...
//
// with decimate[0] pulsed with every 64th sample and decimate[1] 32 samples earlier; read everything on out_valid[0].
//
// Input configuration: WIN=1 is a single-bit PDM stream, in_data being the sign (1:-1, 0:+1) as in cic_decimator_fir.
// WIN>=2 is a two's complement signed integer.
//
// Latch: If decimate[k] is high in cycle t, channel k latches exactly the samples accepted in cycles <= t, for every
// order and any in_valid density; with sparse input, any cycle before the next sample gives the same result.
//
// Output: All orders of channel k update in cycle t+2N+1, together with out_valid[k], and hold until the next update
// or reset. The decimate[k] pulses must be at least 2N-1 cycles apart. Order m of channel k is the two's complement
// q1.(WOUT-1) slice `CIC_DECIMATOR_MULTI_DATA(out_data, WOUT, N, k, m) from cic_decimator_multi.vh; its DC gain is
// R^m/2^G(m) at decimation ratio R, where G(m) = ceil(m*log2(RMAX)), which is unity when R = RMAX is a power of two.
//
// The output of order m is the CIC response to the input (taken as zero before reset) when all intervals between the
// decimate[k] pulses since reset are the same R <= RMAX accepted samples, except the first, which may be shorter.
// A disturbed interval invalidates the next m outputs, a clean change of the period m-1 outputs.
//
// The integrators have max(WIN,2)+G(N) bits. Order m computes on the low max(WIN,2)+G(m) bits of integrator[m-1],
// which is exact due to modular arithmetic, then saturates to WIN+G(m) bits (for WIN=1 this drops the bit needed only
// for +2^G(m), which becomes 2^G(m)-1) and zero-pads or rounds half to even to WOUT bits.
// The default WOUT, `CIC_DECIMATOR_MULTI_WOUT(WIN, RMAX, N), is lossless for every order.
//
// Copyright Zubax Robotics <pavel.kirienko@zubax.com>

`default_nettype none

`include "cic_decimator_multi.vh"


module cic_decimator_multi#(
    // Input width including the sign bit; 1 denotes a single-bit stream, wider are signed two's complenent.
    parameter WIN = 1,
    // The decimation ratio in accepted samples that the widths are sized for; smaller ratios scale the gain down.
    parameter RMAX = 64,
    // Number of integrator stages, which is also the highest order.
    parameter N = 3,
    // Number of comb channels.
    parameter KCOMB = 1,
    // Output slice width; the default is lossless; narrower are correctly rounded-to-nearest, ties-to-even.
    parameter WOUT = `CIC_DECIMATOR_MULTI_WOUT(WIN, RMAX, N)
)(
    input wire clk,
    input wire rst,

    // Data input. The data is accepted when in_valid is asserted.
    input wire in_valid,
    input wire signed [WIN-1:0] in_data,

    // Per-channel latch requests.
    input wire [KCOMB-1:0] decimate,

    // Per-channel output; see cic_decimator_multi.vh for the accessors.
    output reg [KCOMB-1:0] out_valid,
    output reg [WOUT*N*KCOMB-1:0] out_data
);
    generate
        if (WIN < 1)                    begin : g_chk_win   cic_decimator_multi_error_WIN_lt_1 e();         end
        if (RMAX < 2)                   begin : g_chk_rmax  cic_decimator_multi_error_RMAX_lt_2 e();        end
        if (N < 1)                      begin : g_chk_n     cic_decimator_multi_error_N_lt_1 e();           end
        if (KCOMB < 1)                  begin : g_chk_kcomb cic_decimator_multi_error_KCOMB_lt_1 e();       end
        if (WOUT < 2)                   begin : g_chk_wout  cic_decimator_multi_error_WOUT_lt_2 e();        end
        if (((1000'd0 + RMAX) ** N) >= (1000'd1 << 32)) begin : g_chk_gain
            cic_decimator_multi_error_RMAX_pow_N_not_below_2_pow_32 e();  // silently braks in some flows like LSE
        end
    endgenerate

    // A single-bit stream becomes a 2-bit +-1.
    localparam integer WX = (WIN > 1) ? WIN : 2;
    localparam integer WI = WX + `CIC_DECIMATOR_MULTI_GROWTH(RMAX, N);

    wire signed [WX-1:0] in_x;
    generate
        if (WIN == 1) begin : g_in_bitstream
            assign in_x = {in_data[0], 1'b1};  // 0==>+1 (0b01), 1==>-1 (0b11)
        end else begin : g_in_signed
            assign in_x = in_data;
        end
    endgenerate
    wire signed [WI-1:0] in_ext = {{(WI-WX){in_x[WX-1]}}, in_x};  // WI > WX because RMAX >= 2

    // Integrator stages, identical to cic_decimator. A sample accepted in cycle t reaches integrator[i] on the edge
    // closing cycle t+i. Modulo wrapping is acceptable.
    reg  signed [WI-1:0] integrator        [0:N-1];
    wire signed [WI-1:0] integrator_addend [0:N-1];
    assign integrator_addend[0] = in_ext;

    integer i_valid_pipe;
    reg [N-1:0] in_valid_pipe;
    always @ (posedge clk) begin
        if (rst) begin
            in_valid_pipe <= 0;
        end else begin
            in_valid_pipe[0] <= in_valid;
            for (i_valid_pipe = 1; i_valid_pipe < N; i_valid_pipe = i_valid_pipe + 1) begin
                in_valid_pipe[i_valid_pipe] <= in_valid_pipe[i_valid_pipe-1];
            end
        end
    end

    genvar i_int;
    generate
        for (i_int = 1; i_int < N; i_int = i_int + 1) begin : g_integrator_addends
            assign integrator_addend[i_int] = integrator[i_int-1];
        end
        for (i_int = 0; i_int < N; i_int = i_int + 1) begin : g_integrator_stages
            wire enable;
            if (i_int == 0) begin : g_live_enable
                assign enable = in_valid;
            end else begin : g_delayed_enable
                assign enable = in_valid_pipe[i_int-1];
            end
            always @ (posedge clk) begin
                if (rst) begin
                    integrator[i_int] <= 0;
                end else if (enable) begin
                    integrator[i_int] <= integrator[i_int] + integrator_addend[i_int];
                end
            end
        end
    endgenerate

    // Comb channels. The pipe delays decimate[k]: order m latches its tap m cycles later, when the latched samples have
    // reached it, then runs its m comb stages; the outputs of all orders are registered 2N cycles after the request.
    wire [KCOMB-1:0] load;
    wire [WOUT*N*KCOMB-1:0] result;
    genvar k;
    genvar m;
    genvar j;
    generate
        for (k = 0; k < KCOMB; k = k + 1) begin : g_channel
            reg [2*N-1:0] pipe;
            always @ (posedge clk) begin
                if (rst) begin
                    pipe <= 0;
                end else begin
                    pipe <= {pipe[2*N-2:0], decimate[k]};
                end
            end
            assign load[k] = pipe[2*N-1];

            for (m = 1; m <= N; m = m + 1) begin : g_order
                localparam integer M    = m;  // sized, unlike the genvar
                localparam integer WC   = WX  + `CIC_DECIMATOR_MULTI_GROWTH(RMAX, M);
                localparam integer WSAT = WIN + `CIC_DECIMATOR_MULTI_GROWTH(RMAX, M);

                /* verilator lint_off UNUSEDSIGNAL */
                wire signed [WI-1:0] tap = integrator[m-1];  // only the low WC bits are used
                /* verilator lint_on UNUSEDSIGNAL */

                wire signed [WC-1:0] comb_link [0:m];
                assign comb_link[0] = tap[WC-1:0];
                for (j = 0; j < m; j = j + 1) begin : g_comb_stages
                    cic_comb_m1#(WC) comb_inst(
                        .clk(clk),
                        .rst(rst),
                        .enable(pipe[m-1+j]),
                        .x(comb_link[j]),
                        .y(comb_link[j+1])
                    );
                end

                cast_signed#(.WIN(WC), .MSB(WC - WSAT), .LSB(WSAT - WOUT)) cast(
                    .din(comb_link[m]),
                    .dout(`CIC_DECIMATOR_MULTI_DATA(result, WOUT, N, k, m))
                );
            end
        end
    endgenerate

    integer i_load;
    always @ (posedge clk) begin
        if (rst) begin
            out_valid <= 0;
            out_data  <= 0;
        end else begin
            out_valid <= load;
            for (i_load = 0; i_load < KCOMB; i_load = i_load + 1) begin
                if (load[i_load]) begin
                    out_data[WOUT*N*i_load +: WOUT*N] <= result[WOUT*N*i_load +: WOUT*N];
                end
            end
        end
    end
endmodule

