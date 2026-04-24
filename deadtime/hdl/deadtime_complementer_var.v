/// Complementary outputs for a given reference signal with symmetric runtime dead time.
/// pos/neg both low during dead time (break-before-make).
///
/// The deadtime input is synchronous to clk. It is sampled when a dead-time interval starts or restarts,
/// so changes while an interval is active do not affect the active countdown.

module deadtime_complementer_var #(
    parameter DEADTIME_WIDTH = 7  // dead time [clk cycles] input width; shall be at least 1
)(
    input  wire clk,
    input  wire rst,

    // Inputs.
    input  wire in,                             // ideal input signal
    input  wire [DEADTIME_WIDTH-1:0] deadtime,  // dead time in clk cycles; may be zero

    // Outputs.
    output reg  pos,                            // positive signal -- same polarity as the input
    output reg  neg,                            // negative signal -- opposite polarity of the input

    // Diagnostics.
    output wire active                          // dead time is in progress
);
    reg target;
    reg [DEADTIME_WIDTH-1:0] t;

    assign active = t != {DEADTIME_WIDTH{1'b0}};

    always @(posedge clk) begin
        if (rst) begin
            pos <= 1'b0;
            neg <= 1'b0;
            target <= 1'b0;
            t <= {DEADTIME_WIDTH{1'b0}};
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
