/// Converts a signed fixed-point number from one Q format to another by rounding, saturation, and/or extension.
///
/// Saturation is used when Q_WINT(QOUT) < Q_WINT(QIN).
/// Rounding is used when Q_WFRC(QOUT) < Q_WFRC(QIN).
/// Sign-extension is used when Q_WINT(QOUT) > Q_WINT(QIN).
/// LSB zero-padding is used when Q_WFRC(QOUT) > Q_WFRC(QIN).
///
/// Extension and padding are basically no-ops, so there is no cost delay-wise.
/// Saturation is a little more costly because it involves a comparison stage.
/// Rounding is the most expensive.
/// The module will be optimized away entirely if QIN == QOUT.

`include "q.vh"

module q_cast#(parameter QIN = `Q_DEF(1, 31), parameter QOUT = QIN)(
    input  wire signed [`Q_WALL(QIN)-1:0] in,
    output wire signed [`Q_WALL(QOUT)-1:0] out
);
    cast_signed#(.WIN(`Q_WALL(QIN)),
                 .MSB(`Q_WINT(QIN)-`Q_WINT(QOUT)),
                 .LSB(`Q_WFRC(QIN)-`Q_WFRC(QOUT))) u(.din(in), .dout(out));
endmodule
