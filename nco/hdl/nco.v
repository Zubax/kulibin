/// A numerically controlled oscillator (NCO) that outputs a sawtooth wave, whose frequency is a function of
/// clk rate and frequency_control_word, and the amplitude spans the range [0, 2**OUTPUT_WIDTH).
/// The output frequency is defined as:
///
///     f_out = (f_clk * frequency_control_word) / (2**PHASE_ACCUMULATOR_WIDTH)
///
/// Solve for frequency_control_word:
///
///     frequency_control_word = ((2**PHASE_ACCUMULATOR_WIDTH) * f_out) / f_clk
///
/// The phase of the output signal can be adjusted using phase_control_word, which is a value in the range
/// [0, 2**PHASE_ACCUMULATOR_WIDTH) that maps to [0, 2 pi).
///
/// Both of the control words can be changed arbitrarily; changes take effect in the next cycle.

module nco #(
    parameter OUTPUT_WIDTH = 8,                 ///< Larger values reduce phase noise.
    parameter PHASE_ACCUMULATOR_WIDTH = 64      ///< Larger values reduce frequency error.
)
(
    input wire clk,
    input wire rst,
    input wire [PHASE_ACCUMULATOR_WIDTH-1:0] frequency_control_word,
    input wire [PHASE_ACCUMULATOR_WIDTH-1:0] phase_control_word,
    output reg [OUTPUT_WIDTH-1:0]            out
);
    reg  [PHASE_ACCUMULATOR_WIDTH-1:0] acc;
    wire [PHASE_ACCUMULATOR_WIDTH-1:0] phased = acc + phase_control_word;
    reg  [OUTPUT_WIDTH-1:0] fin;
    always @(posedge clk) begin
        if (rst) begin
            acc <= 0;
            fin <= 0;
            out <= 0;
        end else begin
            acc <= acc + frequency_control_word;
            fin <= phased[PHASE_ACCUMULATOR_WIDTH-1:PHASE_ACCUMULATOR_WIDTH-OUTPUT_WIDTH];
            out <= fin;
        end
    end
endmodule
