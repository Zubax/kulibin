/// Cascaded integrator-comb (CIC) filter for decimation by an arbitrary factor.
///
/// The decimation factor (oversampling ratio) R is defined by an external `decimate` signal, which can be
/// triggered at any rate. The number of integrator/comb stages is configurable (N) at synthesis time.
/// The differential delay is fixed to M=1 sample.
///
/// The DC gain is (R M)^N. The output magnitude is thus (x_max (R M)^N), where x_max is the maximum input magnitude.
///
/// The required output bit width is W = W_in + ceil(N * log2(R)). The sign bit is included in W_in>=2.
/// The input bit width is set to W like the output bit width for simplicity, but only some of the low significant
/// bits can be used, depending on the DC gain, which is ultimately controlled at runtime via R (port `decimate`).
/// Single-bit inputs should be signed, which requires 2 bits (+1=0b01, -1=0b11).
///
/// The group delay is: N (R M - 1) / (2 f_s_in).
///
/// https://www.beis.de/Elektronik/DeltaSigma/SigmaDelta.html
/// https://tomverbeure.github.io/2020/09/30/Moving-Average-and-CIC-Filters.html
/// https://www.analog.com/media/en/training-seminars/tutorials/MT-022.pdf?doc=AN-1521.pdf
/// https://www.eecis.udel.edu/~vsaxena/courses/ece697A/s10/Lecture%20Notes/Lecture%2018%20Notes.pdf
/// https://forum.zubax.com/t/greenjets-ares-hs-125-drive-controller/2502/17?u=pavel-kirienko
/// https://www.analog.com/en/resources/technical-articles/sigma-delta-conversion-used-for-motor-control.html
///
/// There is also an interesting alternative construction based on a long delay line:
/// https://github.com/Cognoscan/VerilogCogs/blob/master/sinc3Filter.v

module cic_decimator#(
    parameter W = 17,       // Input/output data width, including the sign bit.
    parameter N = 3         // Number of integrator/comb stages.
)(
    input wire clk,
    input wire rst,

    /// Data input. The data is accepted when in_valid is asserted.
    /// For single-bit inputs, use +1/-1 mapping.
    input wire in_valid,
    input wire signed [W-1:0] in_data,

    /// Decimation control.
    /// After it is asserted, a new decimated output sample will be computed and out_valid will be pulsed.
    input wire decimate,

    /// Downsampled output data is produced after decimation is requested.
    output reg out_valid,
    output wire signed [W-1:0] out_data
);
    initial if (W < 3) $fatal;
    initial if (N < 1) $fatal;

    // Integrator stages.
    // Modulo wrapping is acceptable here, no need to handle overflow.
    reg signed [W-1:0] integrator [0:N-1];
    genvar i_int;
    generate
        for (i_int = 0; i_int < N; i_int = i_int + 1) begin : g_integrator_stages
            always @ (posedge clk) begin
                if (rst) begin
                    integrator[i_int] <= 0;
                end else if (in_valid) begin
                    integrator[i_int] <= integrator[i_int] + ((i_int == 0) ? in_data : integrator[i_int-1]);
                end
            end
        end
    endgenerate

    // Comb stages.
    wire signed [W-1:0] comb_link [0:N];
    assign comb_link[0] = integrator[N-1];
    assign out_data = comb_link[N];
    genvar i_comb;
    generate
        for (i_comb = 0; i_comb < N; i_comb = i_comb + 1) begin : g_comb_stages
            cic_comb_m1#(W) comb_inst(
                .clk(clk),
                .rst(rst),
                .enable(decimate),
                .x(comb_link[i_comb]),
                .y(comb_link[i_comb+1])
            );
        end
    endgenerate

    // Output valid generation.
    always @ (posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
        end else begin
            if (decimate)       out_valid <= 1'b1;
            else if (out_valid) out_valid <= 1'b0;
        end
    end
endmodule
