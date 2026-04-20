/// A generic FIR filter module with a synthesis-time kernel coefficients optimized for high clock frequency.
/// Convolves the kernel with the input signal at every step, keeping (ORDER+1) history samples in memory.
///
/// Typically, the filter will be used with a fixpoint format with only a sign bit for the integer part,
/// with the rest dedicated to the fractional part (e.g., q1.15). The signal itself may be a conventional
/// integer signal; e.g., given q16.0 signal with q1.15 kernel, the output will be in q17.15,
/// which can be cast to q16.0 again to get the same integer format as the input.
/// The fixed point in the input (and output) can be placed arbitrarily without affecting the result.
///
/// If QOUT differs from the default (which is the full accumulator width), the output is converted with saturation
/// and correct rounding-to-nearest, ties-to-even.
///
/// Coeff precision affects frequency response error; input precision sets the noise floor. More coeff bits won't
/// raise SNR beyond the input's quantization limit, but they do preserve stopband attenuation and passband ripple.
///
/// The filter uses only a single pipelined multiply-accumulate operator; for an N-tap filter (N=order+1),
/// the input-output latency is N+6 clk (unless the output is not narrower than the multiply-accumulate register,
/// which would be uncommon, resulting in the latency of only N+5 clk cycles),
/// but the filter is ready to accept a new input after only N+1 cycles.
/// Timing diagram for N=5 (ORDER=4):
///
///                  0   1   2   3   4   5   6   7   8   9   10  11   12
///              ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐  ┌─┐
/// clk=        ─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └──┘ └─
///                ┌───┐
/// in_valid=   ───┘   └─────────────────────────────────────────────────
///             ──────┐                   ┌──────────────────────────────
/// in_ready=         └───────────────────┘
///                                                               ┌───┐
/// out_valid=  ──────────────────────────────────────────────────┘   └──
///
/// See also:
/// - https://fiiir.com/
/// - https://tomverbeure.github.io/2020/09/30/Moving-Average-and-CIC-Filters.html

`include "q.vh"

`default_nettype none

`define QMUL `Q_DEF(`Q_WINT(QIN) + `Q_WINT(QCOEF), \
                    `Q_WFRC(QIN) + `Q_WFRC(QCOEF))

`define QACC `Q_DEF(`Q_WINT(`QMUL) + $clog2(ORDER+1), \
                    `Q_WFRC(`QMUL))

module fir#(
    parameter ORDER     = 10,           // The order is one less than the number of taps/coefficients.
    parameter COEF_FILE = "fir.memb",   // Verilog bin file with signed coefficients as binary fixpoint integers.
    parameter QIN       = `Q_DEF(16, 0),// Input scalar format.
    parameter QCOEF     = `Q_DEF(1, 15),// Kernel coefficients format. Usually q1.x due to coef range [-1, +1].
    parameter QOUT      = `QACC         // Output scalar format; defaults to the accumulator format without narrowing.
)(
    input wire clk,
    input wire rst,
    // Input sample.
    input  wire in_valid,  // Ignored unless in_ready is high.
    output wire in_ready,
    input  wire signed [`Q_WALL(QIN)-1:0] in_data,
    // Output sample.
    output wire out_valid,
    output wire signed [`Q_WALL(QOUT)-1:0] out_data  // Remains stable between out_valid pulses.
);
    localparam N    = ORDER + 1;
    localparam TOP  = N - 1;
    localparam W    = $clog2(N);
    localparam MUL2ACC_EXTEND = `Q_WALL(`QACC) - `Q_WALL(`QMUL);

    // Pipeline stage activity flags.
    reg busy;
    reg memr_valid;  // the memory data requested on the previous cycle is now available
    reg mul0_valid;
    reg mul1_valid;
    reg mul2_valid;  // multipliers can be split into 3 stages very efficiently, with >x2 speedup
    reg acc_valid;

    // Memory indices for convolution.
    reg [W-1:0] i;  // initial x offset upon arrival of new sample
    reg [W-1:0] j;  // current x offset for MAC operation
    reg [W-1:0] k;  // current h offset for MAC operation

    // Memories -- input history and kernel coefficients.
    // See notes regarding async RAM/ROM: https://forum.zubax.com/t/lattice-diamond-usage-notes/2635/7?u=pavel-kirienko
    // This module can work with either sync or async RAM/ROM (e.g., block RAM or distributed or bare registers),
    // but there may be performance implications. If the timings fail to close, provide the RAM/ROM inference hints
    // in the project constraints.
    reg signed [`Q_WALL(QIN)-1:0]   x[0:N-1];
    reg signed [`Q_WALL(QCOEF)-1:0] h[0:N-1];
    initial $readmemb(COEF_FILE, h);

    // Memory read latches to allow both synchronous BRAM or async RAM inference.
    reg signed [`Q_WALL(QIN)-1:0]   x_read;
    reg signed [`Q_WALL(QCOEF)-1:0] h_read;

    // Convolution stages.
    // The critical path of a single FMA is shorter than the sum of separate multiplier+adder chains, but it is still
    // too long to fit into a single clock cycle at high frequencies. Hence, we split it into separate operations,
    // which take longer overall but allow a higher clock rate. We insert empty stages to allow automatic retiming
    // if enabled.
    // The multiply and accumulate operations use full precision, so no rounding/saturation is needed.
    reg signed [`Q_WALL(`QMUL)-1:0] mul0;  // x[j]*h[k]
    reg signed [`Q_WALL(`QMUL)-1:0] mul1;  // dummy stage for retiming
    reg signed [`Q_WALL(`QMUL)-1:0] mul2;  // dummy stage for retiming
    reg signed [`Q_WALL(`QACC)-1:0] acc;   // acc + x[j]*h[k]

    // Saturate and round the output per the requested QOUT format. No-op if QOUT == QACC.
    // The input and output are registers so this doesn't affect the critical path.
    wire acc_last_done = acc_valid && !mul2_valid;
    q_cast_p#(`QACC, QOUT) acc_cast(
        .clk(clk),
        .rst(rst),
        .in_valid(acc_last_done),
        .in(acc),
        .out_valid(out_valid),
        .out(out_data)
    );

    assign in_ready = ~busy;

    // State machine.
    // This is a low-bubble pipeline; we can accept a new input sample while finalizing the previous output.
    integer gen;
    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            memr_valid <= 1'b0;
            mul0_valid <= 1'b0;
            mul1_valid <= 1'b0;
            mul2_valid <= 1'b0;
            acc_valid  <= 1'b0;
            i <= 0;
            j <= 0;
            k <= 0;
            x_read <= 0;
            h_read <= 0;
            mul0 <= 0;
            mul1 <= 0;
            acc  <= 0;
            for (gen = 0; gen < N; gen = gen + 1) begin
`ifndef VERILATOR
                x[gen] <= 0;
`else
                // verilator lint_off BLKSEQ
                x[gen] = 0;
                // verilator lint_on BLKSEQ
`endif
            end
        end else begin
            if (in_valid && ~busy) begin  // only write RAM when not reading from it
                busy <= 1'b1;
                i <= (i == TOP) ? 0 : (i + 1);
                j <= i;           // update the addresses for the synchronous memory read next cycle
                k <= 0;
                x[i] <= in_data;  // synchronous memory write without (!) concurrent read, single-port RAM suffices
            end

            if (busy) begin
                j <= (j == 0) ? TOP : (j - 1);
                memr_valid <= 1'b1;  // memory read data will be available next cycle
                x_read <= x[j];      // allow synchronous BRAM; works with async as well
                h_read <= h[k];
                if (k == TOP) busy <= 1'b0;  // ready to accept next input
                else          k <= k + 1;
            end else begin
                memr_valid <= 1'b0;
            end

            if (memr_valid) begin
                mul0 <= x_read * h_read;
                mul0_valid <= 1'b1;
            end else if (mul0_valid) begin
                mul0_valid <= 1'b0;
            end

            if (mul0_valid) begin
                mul1 <= mul0;  // dummy stage for retiming
                mul1_valid <= 1'b1;
            end else if (mul1_valid) begin
                mul1_valid <= 1'b0;
            end

            if (mul1_valid) begin
                mul2 <= mul1;  // dummy stage for retiming
                mul2_valid <= 1'b1;
            end else if (mul2_valid) begin
                mul2_valid <= 1'b0;
            end

            if (mul2_valid) begin
                // sign-extend explicitly to appease the linter
                acc <= acc + {{MUL2ACC_EXTEND{mul2[`Q_WALL(`QMUL)-1]}}, mul2};  // split FMA for faster clock
                acc_valid <= 1'b1;
            end else if (acc_valid) begin  // pipeline finished; see acc_last_done
                acc <= 0;
                acc_valid <= 1'b0;
            end
        end
    end
endmodule
