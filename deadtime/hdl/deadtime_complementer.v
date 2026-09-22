/// Complementary outputs for a given reference signal with symmetric dead time.
/// pos/neg both low during dead time (break-before-make).
/// Reset drives both outputs low and starts a full dead-time interval.

module deadtime_complementer #(
    parameter DEADTIME = 10  // dead time in clk cycles
)(
    input  wire clk,
    input  wire rst,
    input  wire in,            // ideal input signal
    output reg  pos = 1'b0,    // positive signal -- same polarity as the input
    output reg  neg = 1'b0     // negative signal -- opposite polarity of the input
);
    localparam integer TW = (DEADTIME > 0) ? $clog2(DEADTIME + 1) : 1;

    // Initialized to the same blanked state that reset lands in, so a device whose power-up state is all-zeros
    // does not come up settled -- the one state the reset path above exists to avoid.
    reg target = 1'b0;
    reg active = (DEADTIME > 0);
    reg [TW-1:0] t = (DEADTIME > 0) ? (DEADTIME - 1) : {TW{1'b0}};

    always @(posedge clk) begin
        if (rst) begin
            pos <= 1'b0;
            neg <= 1'b0;
            // target is cleared rather than sampled from in, to keep the reset path free of the input.
            // Either way the interval below is restarted if in disagrees at release, so the guarantee holds.
            target <= 1'b0;
            active <= (DEADTIME > 0);
            t <= (DEADTIME > 0) ? (DEADTIME - 1) : {TW{1'b0}};
        end else if (DEADTIME == 0) begin
            pos <= in;
            neg <= ~in;
            target <= in;
            active <= 1'b0;
            t <= {TW{1'b0}};
        end else begin
            if (!active) begin
                if (in != target) begin  // Edge: blank both and start timer
                    pos <= 1'b0;
                    neg <= 1'b0;
                    target <= in;
                    t <= DEADTIME - 1;
                    active <= 1'b1;
                end else begin
                    pos <=  target;
                    neg <= ~target;
                end
            end else begin                  // Dead time in progress
                if (in != target) begin     // Direction flipped again: retime
                    target <= in;
                    t <= DEADTIME - 1;
                end else if (t != 0) begin
                    t <= t - 1'b1;
                end else begin
                    active <= 1'b0;
                    pos <=  target;
                    neg <= ~target;
                end
            end
        end
    end
endmodule
