/// Complementary outputs for a given reference signal with symmetric dead time.
/// pos/neg both low during dead time (break-before-make).

module deadtime_complementer #(
    parameter DEADTIME = 10  // dead time in clk cycles
)(
    input  wire clk,
    input  wire rst,
    input  wire in,            // ideal input signal
    output reg  pos,           // positive signal -- same polarity as the input
    output reg  neg            // negative signal -- opposite polarity of the input
);
    localparam integer TW = (DEADTIME > 0) ? $clog2(DEADTIME + 1) : 1;

    reg target;
    reg active;
    reg [TW-1:0] t;

    always @(posedge clk) begin
        if (rst) begin
            pos <= 1'b0;
            neg <= 1'b0;
            target <= 1'b0;
            active <= 1'b0;
            t <= {TW{1'b0}};
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
