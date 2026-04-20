/// Fixed-point utilities.
/// The Q-format is specified as a decimal parameter, encoding Qxxx.yyy as a decimal number xxxyyy.
/// E.g., Q8.24 is 8024; Q1.31 is 1031.
/// The sign is included in the width of the integer part, so it cannot be less than 1.
///
/// https://chummersone.github.io/qformat.html#arithmetic
/// https://projectf.io/posts/fixed-point-numbers-in-verilog/

`define Q_WINT(q) ((q)/1000)    /// Bit width of the integer part, including sign bit.
`define Q_WFRC(q) ((q)%1000)    /// Bit width of the fractional part. The integer part may be absent.
`define Q_WALL(q) (`Q_WINT(q) + `Q_WFRC(q))

/// For clarity, produces a decimal number encoding the Q-format from integer and fractional widths.
`define Q_DEF(wi, wf) (((wi)*1000) + (wf))

/// The format required to represent the product of two Q-formats without precision loss.
`define Q_MUL(qa, qb) (`Q_DEF(`Q_WINT(qa) + `Q_WINT(qb), `Q_WFRC(qa) + `Q_WFRC(qb)))

/// The scaling factor, 2^(-fractional_width). The argument is either a Q-format decimal or just the fractional width.
/// This is intended for use in test benches.
///     float = fixed * Q_SCALE(q)
///     fixed = float / Q_SCALE(q)
`define Q_SCALE(q) (2.0**(-`Q_WFRC(q)))
