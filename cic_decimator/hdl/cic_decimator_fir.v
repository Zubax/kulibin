/// A wrapper over the cic_decimator module that adds the output FIR filter for better, fine-tuned frequency response.
/// The differential delay M is fixed to 1 sample.
/// The samples can be fixed-point or signed integers, as the math is invariant to the binary point position.
///
/// The FIR kernel can be designed to both compensate for the CIC droop in the passband and to provide better stopband
/// attenuation with arbitrarily steep roll-off, and with arbitrary frequency response in general.
/// The FIR kernel coefficients are provided in a Verilog binary file (memb) as described below.
/// Use the enclosed Python script to design the FIR kernel for arbitrary desired response.
///
/// The processed samples undergo several width transformations (as this is a multi-rate filter):
///
/// 1. Input WIN bits wide, signed.
///
/// 2. The CIC lowers the sample rate and widens samples to WCIC = max(WIN,2)+ceil(log2(RCIC^NCIC)) bits.
///
/// 3. The CIC output is saturated (MSB-trimmed) to WSAT = WIN+ceil(log2(RCIC^NCIC)). More on this below.
///
/// 4. The CIC output is rounded-to-nearest (LSB-trimmed) to WFIR bits for the FIR input.
///
/// 5. The final FIR output is narrowed to WOUT bits with correct rounding-to-nearest.
///
/// The CIC accumulator width is the same as the CIC output width, and it must be large enough to contain
/// the extreme output values without overflow. The extremes are the minimum and maximum input values multiplied
/// by the CIC DC gain G = (R*M)^N. Given a WIN-bit signed input, the output range is
///
///     [-(2^(WIN-1))*G, +((2^(WIN-1))-1)*G]
///
/// , which nominally requires WCIC = WIN + ceil(log2(G)) bits to represent.
/// A derived parameter is the bit growth = ceil(log2(G)).
/// For example, consider (the specific R and N values are irrelevant for the gain arithmetic):
///
///     WIN     Input range    CIC gain     Output range    CIC bit growth  Output width
///     3       [-4, +3]       8            [-32, +24]      3               6
///     3       [-4, +3]       7            [-28, +21]      3               6
///     3       [-4, +3]       4            [-16, +12]      2               5
///     3       [-4, +3]       3            [-12,  +9]      2               5
///     3       [-4, +3]       2            [ -8,  +6]      1               4
///
/// The output width is thus just wide enough to contain the output range. However, due to the construction of
/// two's complement arithmetic, the case of WIN=1 is special, as the input can only be -1 or 0, which is not useful
/// by itself; we use this case to model symmetric bipolar inputs {-1, +1} by mapping 0==>+1 and -1==>-1.
/// This results in a suboptimal output width where the MSB is only set for a single value, the maximum positive one.
/// Consider:
///
///     WIN     Input range    CIC gain     Output range    CIC bit growth  Output width
///     1==>2   [-1, +1]       8            [-8, +8]        3               5
///     1==>2   [-1, +1]       7            [-7, +7]        3               5
///     1==>2   [-1, +1]       4            [-4, +4]        2               4
///     1==>2   [-1, +1]       3            [-3, +3]        2               4
///     1==>2   [-1, +1]       2            [-2, +2]        1               3
///
/// The output dynamic range of [-G, +G] is symmetric which maps poorly onto two's complement representation
/// if G is a power of two, as the most significant bit is only used to represent the extreme case of +G.
/// We can save one bit of the output width by saturating the output to the range [-G, +G-1],
/// incurring one LSB of error only when the output dynamic range is fully depleted, which is negligible.
/// For this reason, we treat the case of WIN=1 specially:
///
///     WIN     Input range    CIC gain     Output range    CIC bit growth  Output width
///     1==>2   [-1, +1]       8            [-8, +7]        2               4
///     1==>2   [-1, +1]       7            [-7, +7]        2               4
///     1==>2   [-1, +1]       4            [-4, +3]        1               3
///     1==>2   [-1, +1]       3            [-3, +3]        1               3
///     1==>2   [-1, +1]       2            [-2, +1]        0               2

`default_nettype none

`define CIC_BIT_GROWTH(R, N)    $clog2({1000'd0, (R)} ** {1000'd0, (N)})

`define MAX(a, b) (((a) > (b)) ? (a) : (b))

module cic_decimator_fir#(
    /// The input width includes the sign bit.
    /// Single-bit inputs (e.g., from a sigma-delta modulator) are a special case as they only contain the sign bit,
    /// which allows representing only {-1, 0} natively, which is then mapped to -1/+1 inside the module.
    /// E.g., if processing data from a single-bit sigma-delta ADC, set WIN=1 and feed the inverse of the ADC bitstream.
    parameter WIN = 1,

    /// Decimation factor (oversampling ratio).
    parameter RCIC = 32,

    /// Number of integrator/comb stages in the CIC. The CIC DC gain is (R*M)^N = R^N.
    parameter NCIC = 3,

    /// The FIR filter order. The number of taps is (NFIR+1).
    parameter NFIR = 20,

    /// The output bit width, including the sign bit. Defaults to the CIC output width.
    /// This is narrowed with rounding-to-nearest, ties-to-even, from the internal FIR MAC width, which is very wide.
    /// If this value happens to be larger than the MAC width (which is unlikely to make sense),
    /// the output will be LSB-zero-padded to match this width.
    parameter WOUT = WIN + `CIC_BIT_GROWTH(RCIC, NCIC),

    /// Width of the FIR kernel coefficients, including the sign bit.
    /// The coefficients should be fixed-point mapped [-1,+1) => [-2^WK, +2^WK), which is the q1.(WK-1) format.
    /// E.g., for q1.15, WK=16, [-1,+1) => [-32768, +32767].
    /// The default is to use the same width as WOUT.
    parameter WK = WOUT,

    /// The maximum width of the sample fed to the FIR filter, including the sign bit.
    /// The CIC output is rounded-to-nearest-ties-to-even to match this width.
    /// If the CIC output is narrower than this, this value will have no effect -- no extension is performed.
    /// The default is expected to be suitable for most applications, so it rarely needs to be overridden.
    parameter WFIR = `MAX(WK, WOUT),

    // FIR kernel coefficients in the q1.w fixed-point format, where w=(WK-1), stored in a Verilog binary file (memb).
    // The coefficients normally should sum to unity (DC gain = 1) to preserve the gain of the CIC filter.
    // Usually this path is relative to the project directory, at least for Synplify Pro (see help).
    parameter KERNEL = "fir.memb"
)(
    input wire clk,
    input wire rst,

    /// Data input. The data is accepted when in_valid is asserted.
    /// The in_valid rate divided by RCIC, aka the output rate, expressed in clk cycles, must not exceed the
    /// FIR computation delay, which is a little more than NFIR clk cycles; otherwise, samples will be skipped.
    /// For single-bit inputs (WIN=1), the in_data is simply the sign: 1==>-1, 0==>+1.
    input wire in_valid,
    input wire signed [WIN-1:0] in_data,

    /// Filtered output data. The output rate is in_valid/RCIC.
    output wire out_valid,
    output wire signed [WOUT-1:0] out_data
);
    // Decimation counter that defines RCIC.
    localparam WCNT = `MAX($clog2(RCIC), 1);
    reg [WCNT-1:0] dec_cnt;
    wire dec_cnt_top = (dec_cnt == RCIC-1);
    reg cic_decimate;
    always @ (posedge clk) begin
        if (rst) begin
            dec_cnt <= 0;
            cic_decimate <= 1'b0;
        end else begin
            if (in_valid) begin
                dec_cnt <= dec_cnt_top ? 0 : (dec_cnt + 1);
            end
            if (in_valid && dec_cnt_top) cic_decimate <= 1'b1;
            else if (cic_decimate) cic_decimate <= 1'b0;
        end
    end

    // CIC filter stage.
    // The case of WIN=1 is special because we map it to {-1,+1}, thereby adding one extra bit, so we have to take
    // that into account here to avoid overflow inside the CIC.
    localparam WCIC = `MAX(WIN, 2) + `CIC_BIT_GROWTH(RCIC, NCIC);
    wire signed [WCIC-1:0] cic_in = {
        {(WCIC-WIN){in_data[WIN-1]}},           // sign extension
        (WIN > 1) ? in_data : {{WIN{1'b1}}}     // special case WIN=1: map 0==>+1, -1==>-1
    };
    wire cic_out_valid;
    wire signed [WCIC-1:0] cic_out;
    cic_decimator#(
        .W(WCIC),
        .N(NCIC)
    ) cic(
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_data(cic_in),
        .decimate(cic_decimate),
        .out_valid(cic_out_valid),
        .out_data(cic_out)
    );

    // Remove excess bits from CIC safely with saturation and rounding.
    // The case of WIN=1 requires saturation as explained earlier.
    localparam WSAT = WIN + `CIC_BIT_GROWTH(RCIC, NCIC);
    localparam WF = (WSAT < WFIR) ? WSAT : WFIR;  // Avoid extension, it adds no new information.
    wire cast_out_valid;
    wire signed [(WF-1):0] cast_out;
    cast_signed_p#(
        .WIN(WCIC),
        .MSB(WCIC-WSAT),
        .LSB(WSAT-WF)
    ) cast (
        .clk(clk),
        .rst(rst),
        .in_valid(cic_out_valid),
        .in_data(cic_out),
        .out_valid(cast_out_valid),
        .out_data(cast_out)
    );

    // FIR filter stage.
    // Our inputs are integers, but we treat them as fixed-point in the range [-1,+1).
    // verilator lint_off PINCONNECTEMPTY
    fir#(
        .ORDER(NFIR),
        .COEF_FILE(KERNEL),
        .QIN  (1000 + WF   - 1),    // q1.(WF-1)
        .QCOEF(1000 + WK   - 1),    // q1.(WK-1)
        .QOUT (1000 + WOUT - 1)     // q1.(WOUT-1) using 1 integer bit here allows automatic extension
    ) u_fir (
        .clk(clk),
        .rst(rst),
        // Input sample from CIC after saturation and rounding.
        .in_valid(cast_out_valid),
        .in_ready(),
        .in_data(cast_out),
        // Filtered output.
        .out_valid(out_valid),
        .out_data(out_data)
    );
    // verilator lint_on PINCONNECTEMPTY
endmodule
