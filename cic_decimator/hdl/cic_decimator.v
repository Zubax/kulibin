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
    /// Once asserted, a new decimated output will be computed and out_valid pulsed after the comb pipeline delay.
    input wire decimate,

    /// Downsampled output data is valid when out_valid is asserted.
    output wire out_valid,
    output wire signed [W-1:0] out_data
);
    initial if (W < 2) $fatal;
    initial if (N < 1) $fatal;

    // Integrator stages. Modulo wrapping is acceptable here, no need to handle overflow.
    // The decimate input is caller-controlled and intentionally independent from in_valid. A sample accepted on
    // clock t reaches the final integrator after clock t+N-1, but the comb samples the pre-clock integrator state.
    // Therefore, assert decimate at t+N or later to include that sample; earlier decimation samples the older state.
    reg  signed [W-1:0] integrator        [0:N-1];
    wire signed [W-1:0] integrator_addend [0:N-1];
    assign integrator_addend[0] = in_data;

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

    // Comb stages.
    wire signed [W-1:0] comb_link [0:N];
    assign comb_link[0] = integrator[N-1];

    integer i_pipe;
    reg [N-1:0] decimate_pipe;
    always @ (posedge clk) begin
        if (rst) begin
            decimate_pipe <= 0;
        end else begin
            decimate_pipe[0] <= decimate;
            for (i_pipe = 1; i_pipe < N; i_pipe = i_pipe + 1) begin
                decimate_pipe[i_pipe] <= decimate_pipe[i_pipe-1];
            end
        end
    end

    genvar i_comb;
    generate
        for (i_comb = 0; i_comb < N; i_comb = i_comb + 1) begin : g_comb_stages
            wire enable;
            if (i_comb == 0) begin : g_live_enable
                assign enable = decimate;
            end else begin : g_delayed_enable
                assign enable = decimate_pipe[i_comb-1];
            end
            cic_comb_m1#(W) comb_inst(
                .clk(clk),
                .rst(rst),
                .enable(enable),
                .x(comb_link[i_comb]),
                .y(comb_link[i_comb+1])
            );
        end
    endgenerate

    assign out_data  = comb_link[N];
    assign out_valid = decimate_pipe[N-1];
endmodule
