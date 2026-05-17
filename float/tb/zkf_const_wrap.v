/// Testbench harness for zkf_const. cocotb cannot pass `real` parameters via plusargs, so this module hardcodes a
/// curated set of VALUE constants and exposes their packed outputs as named ports. The Python test reads each port
/// and compares against the reference packer in zkf_model.py.

`default_nettype none

module zkf_const_wrap #(parameter WEXP = 6, parameter WMAN = 18) (
    output wire [WEXP+WMAN-1:0] y_zero,
    output wire [WEXP+WMAN-1:0] y_neg_zero,
    output wire [WEXP+WMAN-1:0] y_one,
    output wire [WEXP+WMAN-1:0] y_neg_one,
    output wire [WEXP+WMAN-1:0] y_two,
    output wire [WEXP+WMAN-1:0] y_half,
    output wire [WEXP+WMAN-1:0] y_pi,
    output wire [WEXP+WMAN-1:0] y_neg_pi,
    output wire [WEXP+WMAN-1:0] y_e,
    output wire [WEXP+WMAN-1:0] y_ln2,
    output wire [WEXP+WMAN-1:0] y_sqrt2,
    output wire [WEXP+WMAN-1:0] y_third,
    output wire [WEXP+WMAN-1:0] y_pos_inf,
    output wire [WEXP+WMAN-1:0] y_neg_inf
);
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 0.0))                u_zero    (.y(y_zero));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE(-0.0))                u_neg_zero(.y(y_neg_zero));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 1.0))                u_one     (.y(y_one));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE(-1.0))                u_neg_one (.y(y_neg_one));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 2.0))                u_two     (.y(y_two));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 0.5))                u_half    (.y(y_half));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 3.141592653589793))  u_pi      (.y(y_pi));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE(-3.141592653589793))  u_neg_pi  (.y(y_neg_pi));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 2.718281828459045))  u_e       (.y(y_e));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 0.6931471805599453)) u_ln2     (.y(y_ln2));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 1.4142135623730951)) u_sqrt2   (.y(y_sqrt2));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .VALUE( 1.0/3.0))            u_third   (.y(y_third));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .INF(+1))                    u_pos_inf (.y(y_pos_inf));
    zkf_const #(.WEXP(WEXP), .WMAN(WMAN), .INF(-1))                    u_neg_inf (.y(y_neg_inf));
endmodule

`default_nettype wire
