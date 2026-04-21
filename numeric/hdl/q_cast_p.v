/// Converts a signed fixed-point number from one Q format to another by rounding, saturation, and/or extension,
/// pipelined into 1 or 2 clock cycles with the throughput of one value per cycle (no wait states).
/// If the output format requires only one of saturation or rounding, the pipeline is 1 cycle.
/// If the output format requires both saturation and rounding, the pipeline is 2 cycles.
///
/// Saturation is used when Q_WINT(QOUT) < Q_WINT(QIN).
/// Rounding-to-nearest, ties-to-even is used when Q_WFRC(QOUT) < Q_WFRC(QIN).
/// Sign-extension is used when Q_WINT(QOUT) > Q_WINT(QIN).
/// LSB zero-padding is used when Q_WFRC(QOUT) > Q_WFRC(QIN).
///
/// Extension and padding are basically no-ops, in which case the non-pipelined version may be preferred.
/// Saturation is a little more costly because it involves a comparison stage.
/// Rounding is the most expensive.

`include "q.vh"

module q_cast_p#(parameter QIN = `Q_DEF(1, 31), parameter QOUT = QIN)(
    input wire clk,
    input wire rst,
    // Input.
    input wire in_valid,
    input wire signed [`Q_WALL(QIN)-1:0] in,
    // Output.
    // The output value remains stable between out_valid pulses.
    output wire out_valid,
    output wire signed [`Q_WALL(QOUT)-1:0] out
);
    localparam MSB = `Q_WINT(QIN)-`Q_WINT(QOUT);
    localparam LSB = `Q_WFRC(QIN)-`Q_WFRC(QOUT);
    generate
        if ((MSB > 0) || (LSB > 0)) begin : g_cast
            cast_signed_p#(.WIN(`Q_WALL(QIN)), .MSB(MSB), .LSB(LSB)) cast (
                .clk(clk),
                .rst(rst),
                .in_valid(in_valid),
                .in_data(in),
                .out_valid(out_valid),
                .out_data(out)
            );
        end else begin : g_bypass
            wire signed [`Q_WALL(QOUT)-1:0] result;
            cast_signed#(.WIN(`Q_WALL(QIN)), .MSB(MSB), .LSB(LSB)) cast (.din(in), .dout(result));
            reg  signed [`Q_WALL(QOUT)-1:0] result_d;
            reg  done;
            assign out_valid = done;
            assign out = result_d;
            always @(posedge clk) begin
                if (rst) begin
                    result_d <= 0;
                    done     <= 0;
                end else begin
                    if (in_valid) begin
                        done <= 1;
                        result_d <= result;
                    end else if (done) begin
                        done <= 0;
                    end
                end
            end
        end
    endgenerate
endmodule
