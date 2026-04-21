/// Samples a sigma-delta modulator bitstream and generates a matching center-aligned PWM signal
/// with complementary outputs with dead time.
/// The PWM frequency equals the ADC PCM stream rate.

`default_nettype none

module sdadc_to_pwm#(
    parameter W = 12,

    /// The complementary output dead time is specified in clk periods.
    parameter DEADTIME = 10,

    // clk frequency divided by the sigma-delta bitstream rate.
    // Higher values provide greater PWM resolution.
    parameter FREQ_RATIO = 5,

    /// Refer to cic_decimator_fir for the description of these parameters.
    parameter RCIC  = 128,  // The update frequency equals the sigma-delta sample rate divided by RCIC
    parameter NCIC  = 3,
    parameter NFIR  = 12,   // must match the FIR kernel file
    parameter WK    = 17,   // must match the FIR kernel file
    parameter KERNEL = "62eab2361fc4dbf9.fir.memb"
)(
    input wire clk,
    input wire rst,

    // Sigma-delta bitstream input.
    input wire in_sd_bit_valid,
    input wire in_sd_bit,

    // When the output is not enabled, both complementary outputs are grounded regardless of the input.
    // The input DSP pipeline is working normally though; the outputs can be re-enabled immediately.
    input wire out_enable,

    // Complementary PWM output.
    output wire out_pwm_pos,
    output wire out_pwm_neg,

    // Diagnostic signed PCM value for observability, prior to mapping to the PWM range.
    output wire                out_pcm_valid,  // Pulsed when updated.
    output wire signed [W-1:0] out_pcm
);
    // PDM to PCM conversion stage using a cascaded CIC+FIR filter.
    wire pcm_valid;
    wire signed [W-1:0] pcm;
    cic_decimator_fir#(
        .WIN(1),
        .RCIC(RCIC),
        .NCIC(NCIC),
        .NFIR(NFIR),
        .WOUT(W),
        .WK(WK),
        .KERNEL(KERNEL)
    ) cicfir (
        .clk(clk),
        .rst(rst),
        .in_valid(in_sd_bit_valid),
        .in_data(~in_sd_bit),  // the ADC input becomes the sign bit
        .out_valid(pcm_valid),
        .out_data(pcm)
    );
    assign out_pcm_valid = pcm_valid;
    assign out_pcm = pcm;

    // Scale the PCM signal to match the PWM dynamic range.
    // Also bias the signal by half-range to make it unsigned.
    //
    //     import sympy as sp
    //     f_clk, pwm_top, f_ratio_clk_sd, R_cic = sp.symbols('f_clk pwm_top f_ratio_clk_sd R_cic',
    //                                                        reals=True, positive=True)
    //     f_pwm = f_clk / (2 * pwm_top)
    //     f_sd  = f_clk / f_ratio_clk_sd
    //     f_pcm = f_sd / R_cic
    //     # The PWM frequency can be either equal to PCM or half of that.
    //     # This is because the shadow registers are reloaded twice per PWM period.
    //     f_pwm_mult = sp.Rational(1, 2)
    //     sp.solve(sp.Eq(f_pwm, f_pwm_mult * f_pcm), pwm_top, manual=True)
    //
    // The scaling below uses $signed(PWM_TOP), so PWM_TOP shall fit into a positive signed W-bit integer.
    localparam integer PWM_TOP_VALUE = RCIC * FREQ_RATIO;
    localparam [W-1:0] PWM_TOP = PWM_TOP_VALUE;
    initial if ((PWM_TOP_VALUE <= 0) || (PWM_TOP != PWM_TOP_VALUE) || PWM_TOP[W-1]) $fatal;

    reg                  scaled_v[2:0];
    reg signed [W*2-1:0] scaled_d[2:0];  // dummy stages for retiming the multiplication.
    wire                scaled_signed_valid;
    wire signed [W-1:0] scaled_signed;
    q_cast_p#(
        .QIN(1000 + W + W-1),   // convert into fixpoint [-0.5,+0.5): q0.16 * q1.15 => q1.31
        .QOUT(1000 + W-1)       // q1.15 [-0.5,+0.5) representing PWM_TOP scaled as [-PWM_TOP/2,+PWM_TOP/2).
    ) scaled_cast (
        .clk(clk),
        .rst(rst),
        .in_valid(scaled_v[2]),
        .in(scaled_d[2]),
        .out_valid(scaled_signed_valid),
        .out(scaled_signed)
    );
    reg         scaled_unsigned_valid;
    reg [W-1:0] scaled_unsigned;
    integer g_idx;
    always @(posedge clk) begin
        if (rst) begin
            for (g_idx = 0; g_idx < 3; g_idx = g_idx + 1) begin
                scaled_v[g_idx] <= 0;
                scaled_d[g_idx] <= 0;
            end
            scaled_unsigned_valid <= 0;
            scaled_unsigned <= 0;
        end else begin
            if (pcm_valid) begin
                scaled_d[0] <= pcm * $signed(PWM_TOP);
                scaled_v[0] <= 1;
            end else if (scaled_v[0]) begin
                scaled_v[0] <= 0;
            end

            if (scaled_v[0]) begin
                scaled_d[1] <= scaled_d[0];  // multiplication retiming stage
                scaled_v[1] <= 1;
            end else if (scaled_v[1]) begin
                scaled_v[1] <= 0;
            end

            if (scaled_v[1]) begin
                scaled_d[2] <= scaled_d[1];  // multiplication retiming stage
                scaled_v[2] <= 1;
            end else if (scaled_v[2]) begin
                scaled_v[2] <= 0;
            end

            if (scaled_signed_valid) begin
                scaled_unsigned <= scaled_signed + $signed(PWM_TOP >>> 1);  // bias by half-range to make unsigned
                scaled_unsigned_valid <= 1;
            end else if (scaled_unsigned_valid) begin
                scaled_unsigned_valid <= 0;
            end
        end
    end

    // PWM reference generator.
    wire pwm_ref;
    up_down_pwm#(W) pwm_gen (
        .clk(clk),
        .rst(rst),
        .top(PWM_TOP),
        .compare(scaled_unsigned),
        .at_top(),
        .at_bot(),
        .out(pwm_ref)
    );

    /// Complementary output generator.
    wire pwm_pos;
    wire pwm_neg;
    deadtime_complementer#(DEADTIME) deadtime (
        .clk(clk),
        .rst(rst),
        .in(pwm_ref),
        .pos(pwm_pos),
        .neg(pwm_neg)
    );
    assign out_pwm_pos = pwm_pos & out_enable;
    assign out_pwm_neg = pwm_neg & out_enable;
endmodule
