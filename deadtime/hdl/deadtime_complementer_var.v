/// Complementary outputs for a given reference signal with symmetric runtime dead time.
/// pos/neg both low during dead time (break-before-make).
///
/// The deadtime input is synchronous to clk. It is sampled when a dead-time interval starts or restarts,
/// so changes while an interval is active do not affect the active countdown.
///
/// Reset drives both outputs low and starts a dead-time interval of the longest representable length, so the
/// first output assertion after reset release is at least that far away. Held at a constant input across reset,
/// the module blanks for 2**DEADTIME_WIDTH-1 cycles before asserting anything. The first input edge cuts that
/// short, restarting the interval with the deadtime presented then, exactly as any other edge does.

module deadtime_complementer_var #(
    parameter DEADTIME_WIDTH = 7  // dead time [clk cycles] input width; shall be at least 1
)(
    input  wire clk,
    input  wire rst,

    // Inputs.
    input  wire in,                             // ideal input signal
    input  wire [DEADTIME_WIDTH-1:0] deadtime,  // dead time in clk cycles; may be zero

    // Outputs.
    output reg  pos = 1'b0,                     // positive signal -- same polarity as the input
    output reg  neg = 1'b0,                     // negative signal -- opposite polarity of the input

    // Diagnostics.
    output wire active                          // dead time is in progress
);
    // Initialized blanked, like the state reset lands in, so a device whose power-up state is all-zeros does not
    // come up settled -- the one state the reset path exists to avoid. The deadtime input cannot be read at power
    // up, so the longest representable interval is used; it is only ever shortened by the first edge.
    reg target = 1'b0;
    reg [DEADTIME_WIDTH-1:0] t = {DEADTIME_WIDTH{1'b1}};

    assign active = t != {DEADTIME_WIDTH{1'b0}};

    always @(posedge clk) begin
        if (rst) begin
            pos <= 1'b0;
            neg <= 1'b0;
            // Neither the target nor the interval is taken from an input: the reset state must not depend on a
            // value that is not synchronous to the reset. See the header for what this costs at startup.
            target <= 1'b0;
            t <= {DEADTIME_WIDTH{1'b1}};
        end else if (in != target) begin  // Edge or reversal: sample the current deadtime and retime.
            target <= in;
            if (deadtime == {DEADTIME_WIDTH{1'b0}}) begin
                pos <= in;
                neg <= ~in;
                t <= {DEADTIME_WIDTH{1'b0}};
            end else begin
                pos <= 1'b0;
                neg <= 1'b0;
                t <= deadtime;
            end
        end else if (t > 1'b1) begin
            pos <= 1'b0;
            neg <= 1'b0;
            t <= t - 1'b1;
        end else begin
            pos <= target;
            neg <= ~target;
            t <= {DEADTIME_WIDTH{1'b0}};
        end
    end
endmodule
