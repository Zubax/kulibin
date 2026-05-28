/// Streamed base-2 exponential for the Zubax Kulibin float format: y = 2**x.
/// Zero-bubble, throughput-1, no backpressure.
/// Register stages: STAGE_INPUT + 5 + D*(2+STAGE_PRODUCT) + STAGE_OUTPUT, where D depends on WMAN per the table below.
/// Behavior:
///
///   exp2(-inf)   = +0
///   exp2(+0)     = 1.0
///   exp2(finite) = 2**x, round-to-nearest ties-to-even
///   exp2(+inf)   = +inf
///   tiny finite results follow the zero/MIN_NORMAL boundary rule; overflow maps to +inf
///
/// Algorithm:
///
///  1. Split x = i + f with i = floor(x) and f in [0,1) by shifting the significand by the exponent into a fixed-point
///     value (the zkf_to_int float->fixed front end, keeping the fraction).
///
///  2. Then 2**x = 2**f * 2**i, where 2**f in [1,2) is a normalized significand produced by the pipelined per-WMAN
///     table+polynomial core selected by the generate-if below (hdl/_tables/_zkf_exp2_m<WMAN>_d<D>.v).
///
///  3. The result is packed with exponent i via _zkf_pack, which applies overflow->inf and the tiny/MIN_NORMAL boundary.
///
/// The reduction is split across register stages (shift-amount computation, barrel shift, negate) and the evaluator's
/// ROM read is registered, so no single stage carries both a wide carry chain and a multiply.
///
/// STAGE_PRODUCT={0,1} splits the Horner multiply for timing closure (like zkf_mul).
/// STAGE_OUTPUT={0,1} registers the output.

`default_nettype none

module zkf_exp2 #(
    parameter WEXP          = 6,    // exponent field width
    parameter WMAN          = 18,   // significand precision including the hidden bit
    parameter STAGE_INPUT   = 0,    // 0: combinational inputs;   1: latch inputs before any logic, +1 stage
    parameter STAGE_PRODUCT = 0,    // 0: single Horner multiply; 1: split (2x2), +1 stage per degree
    parameter STAGE_OUTPUT  = 0     // 0: combinational outputs;  1: registered outputs, +1 stage
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] x,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y
);
    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wman
            _zkf_invalid_wexp_or_wman u_invalid();
        end
        // BIAS / threshold constants below use unsized integer shifts on WEXP; WEXP >= 31 would overflow Verilog's
        // 32-bit integer constant arithmetic.
        if (WEXP >= 31) begin : g_invalid_wexp_too_wide
            _zkf_invalid_exp2_wexp_too_wide_unportable u_invalid();
        end
    endgenerate
    // verilator coverage_on

    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;
    // FF: fraction bits kept for the reduced argument f. MUST equal the generator's GUARD_FF (zkf_transcendental.py).
    localparam FF        = WMAN + 12;
    localparam SHIFT_OFF = FF - WFRAC;          // = 13: shift = e + SHIFT_OFF places the binary point at bit FF
    localparam WEU       = WEXP + 2;            // signed unbiased exponent fed to _zkf_pack
    localparam WV        = WMAN + WEXP + 14;    // fixed-point value width (>= sig<<lshamt_max and >= i*2^FF)
    // Signed shift accumulator: must hold shift = e + SHIFT_OFF over e in [-(2^(WEXP-1)), 2^(WEXP-1)] and the
    // constant SHIFT_OFF = 13, so it needs more than WEXP bits at small WEXP (where 13 dominates).
    localparam WSH       = WEXP + 7;
    localparam LSHAMT_MAX = WEXP + 11;          // largest useful left shift (in-range e); larger e is forced anyway
    localparam WLS       = $clog2(LSHAMT_MAX + 1);
    localparam WRS       = $clog2(WMAN + 1);    // right shift saturates at WMAN (beyond it the magnitude is 0)
    localparam SBW       = WEU + 4;             // evaluator sideband: {i, force_inf, force_zero, is_zero, lost_sticky}

    localparam integer BIAS    = (1 << (WEXP - 1)) - 1;
    // |x| >= 2^(WEXP-1) is always out of range. exp >= OOR_THRESHOLD <=> e >= WEXP-1 (also true for +/-inf).
    localparam integer OOR_THRESHOLD = BIAS + WEXP - 1;

    // -- Optional input register stage (latch x ahead of the decode/reduction cone).
    wire             in_valid_q;
    wire [WFULL-1:0] x_q;
    _zkf_pipe #(.W(WFULL), .N(STAGE_INPUT ? 1 : 0)) u_input_pipe (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in(x), .out_valid(in_valid_q), .out(x_q)
    );

    // -- Decode and classify.
    wire             sign_in       = x_q[WFULL-1];
    wire [WEXP-1:0]  exp_in        = x_q[WFULL-2:WFRAC];
    wire [WFRAC-1:0] frac_in       = x_q[WFRAC-1:0];
    wire             is_zero       = ~|exp_in;
    wire [WMAN-1:0]  sig_in        = {1'b1, frac_in};
    wire             oor           = exp_in >= OOR_THRESHOLD[WEXP-1:0]; // covers +/-inf and gross over/underflow
    wire             force_inf_in  = oor & ~sign_in;                    // +inf or positive overflow
    wire             force_zero_in = oor &  sign_in;                    // -inf or negative underflow

    // -- Argument reduction, stage RA (combinational): compute the shift amounts as parallel single subtracts/compares
    // of exp against folded constants (the zkf_to_int approach), instead of a dependent e->shift->abs->clamp chain.
    // The binary point goes at bit FF, so shift = (e - WFRAC) + FF = e + SHIFT_OFF = exp - C_SHIFT.
    localparam integer C_SHIFT = BIAS - SHIFT_OFF;   // shift = exp - C_SHIFT
    localparam integer RUNDER  = C_SHIFT - WMAN;     // exp < RUNDER  => the right shift saturates (amount > WMAN)
    localparam integer MAX_EXP = (1 << WEXP) - 1;
    // verilator coverage_off
    wire signed [WSH-1:0] exp_ext   = $signed({1'b0, exp_in});
    wire signed [WSH-1:0] c_shift_s = $signed(C_SHIFT[WSH-1:0]);
    wire signed [WSH-1:0] left_amt  = exp_ext - c_shift_s;          // = shift (>= 0 for a left shift)
    wire signed [WSH-1:0] right_amt = c_shift_s - exp_ext;          // = -shift (> 0 for a right shift)
    wire is_left;
    wire rsh_over;
    // verilator coverage_on
    generate
        if (C_SHIFT <= 0)           begin : g_left_always  assign is_left  = 1'b1; end
        else if (C_SHIFT > MAX_EXP) begin : g_left_never   assign is_left  = 1'b0; end
        else                        begin : g_left_cmp     assign is_left  = exp_in >= C_SHIFT[WEXP-1:0]; end
        if (RUNDER <= 0)            begin : g_rover_never  assign rsh_over = 1'b0; end
        else if (RUNDER > MAX_EXP)  begin : g_rover_always assign rsh_over = 1'b1; end
        else                        begin : g_rover_cmp    assign rsh_over = exp_in < RUNDER[WEXP-1:0]; end
    endgenerate
    // The left shift saturates exactly when the input is out of range (LSHAMT_MAX = the max in-range left shift), so
    // lsh_over == oor. lshamt/rshamt are don't-care for the non-selected direction (mag_v picks one), so the clamps
    // need only be correct in their own direction.
    wire [WLS-1:0] lshamt = oor      ? LSHAMT_MAX[WLS-1:0] : left_amt[WLS-1:0];
    wire [WRS-1:0] rshamt = rsh_over ? WMAN[WRS-1:0]       : right_amt[WRS-1:0];

    // -- Stage RA register: capture the shift amounts and significand, separating the amount computation from the
    // barrel shift so neither stage carries both a wide carry chain and a wide variable shift.
    reg                 ra_valid;
    reg                 ra_sign;
    reg                 ra_is_left;
    reg [WMAN-1:0]      ra_sig;
    reg [WLS-1:0]       ra_lshamt;
    reg [WRS-1:0]       ra_rshamt;
    reg                 ra_force_inf;
    reg                 ra_force_zero;
    reg                 ra_is_zero;
    always @(posedge clk) begin
        if (rst) ra_valid <= 1'b0;
        else     ra_valid <= in_valid_q;
        ra_sign       <= sign_in;
        ra_is_left    <= is_left;
        ra_sig        <= sig_in;
        ra_lshamt     <= lshamt;
        ra_rshamt     <= rshamt;
        ra_force_inf  <= force_inf_in;
        ra_force_zero <= force_zero_in;
        ra_is_zero    <= is_zero;
    end

    // -- Stage RB1 (combinational): apply the barrel shift to form the magnitude |x| * 2^FF.
    // verilator coverage_off
    wire [WMAN-1:0]  f_right        = ra_sig >> ra_rshamt;
    wire [WMAN-1:0]  drop_mask      = ~({WMAN{1'b1}} << ra_rshamt);     // low ra_rshamt bits set
    wire             right_lost     = |(ra_sig & drop_mask);
    wire [WV-1:0]    mag_left       = {{(WV-WMAN){1'b0}}, ra_sig} << ra_lshamt;
    wire [WV-1:0]    mag_right      = {{(WV-WMAN){1'b0}}, f_right};
    wire [WV-1:0]    mag_v          = ra_is_left ? mag_left : mag_right;
    wire             lost_sticky_in = ra_is_left ? 1'b0 : right_lost;
    // verilator coverage_on

    // -- Stage RB1 register: capture the shifted magnitude, separating the barrel shift from the negate/split.
    reg                  rb_valid;
    // verilator coverage_off
    reg        [WV-1:0]  rb_mag;
    // verilator coverage_on
    reg                  rb_sign;
    reg                  rb_force_inf;
    reg                  rb_force_zero;
    reg                  rb_is_zero;
    reg                  rb_lost;
    always @(posedge clk) begin
        if (rst) rb_valid <= 1'b0;
        else     rb_valid <= ra_valid;
        rb_mag        <= mag_v;
        rb_sign       <= ra_sign;
        rb_force_inf  <= ra_force_inf;
        rb_force_zero <= ra_force_zero;
        rb_is_zero    <= ra_is_zero;
        rb_lost       <= lost_sticky_in;
    end

    // -- Stage RB2 (combinational): two's-complement value, split into i = floor and the FF-bit fraction f.
    // verilator coverage_off
    wire signed [WV:0]    v_signed = rb_sign ? (~{1'b0, rb_mag} + {{WV{1'b0}}, 1'b1}) : {1'b0, rb_mag};
    wire signed [WV-FF:0] i_full   = v_signed[WV:FF];              // = floor(x) (oversized; truncated to WEU below)
    wire [FF-1:0]         f_bits   = v_signed[FF-1:0];
    // verilator coverage_on
    wire signed [WEU-1:0] i_clamped = i_full[WEU-1:0];             // |i| < 2^(WEXP-1) for in-range inputs

    // -- Stage RB2 register: the reduction result feeding the pipelined evaluator.
    reg                  r0_valid;
    reg signed [WEU-1:0] r0_i;
    reg        [FF-1:0]  r0_f;
    reg                  r0_force_inf;
    reg                  r0_force_zero;
    reg                  r0_is_zero;
    reg                  r0_lost;
    always @(posedge clk) begin
        if (rst) r0_valid <= 1'b0;
        else     r0_valid <= rb_valid;
        r0_i          <= i_clamped;
        r0_f          <= f_bits;
        r0_force_inf  <= rb_force_inf;
        r0_force_zero <= rb_force_zero;
        r0_is_zero    <= rb_is_zero;
        r0_lost       <= rb_lost;
    end

    // -- Pipelined evaluator: 2**f significand + GRS. The sideband {i, force_inf, force_zero, is_zero, lost} is delayed
    // to land with the significand, so this module need not know the evaluator's internal depth (1+D cycles).
    wire [SBW-1:0]  sb_in_e = {r0_i, r0_force_inf, r0_force_zero, r0_is_zero, r0_lost};
    wire            ev_valid;
    wire [SBW-1:0]  sb_out_e;
    wire [WMAN-1:0] eval_sig;
    wire            eval_guard;
    wire            eval_round;
    wire            eval_sticky;
    // The table+polynomial core is pre-generated per WMAN using zkf_transcendental.py as _zkf_exp2_m<WMAN>_d<D>,
    // D = degree(WMAN). The D arguments are the closed-form degree(WMAN); a stale value would name a now-missing
    // module and fail loudly.
    `define ZKF_EXP2_TABLE(W, D) end else if (WMAN == W) begin : g_m``W \
        _zkf_exp2_m``W``_d``D #(.SBW(SBW), .STAGE_PRODUCT(STAGE_PRODUCT)) u_eval ( \
            .clk(clk), .rst(rst), .in_valid(r0_valid), .sb_in(sb_in_e), .f(r0_f), \
            .out_valid(ev_valid), .sb_out(sb_out_e), .significand(eval_sig), \
            .guard(eval_guard), .round(eval_round), .sticky(eval_sticky));
    generate
        if (1'b0) begin : g_none  // seed: the macro opens with "end else if", so every table line is uniform
        `ZKF_EXP2_TABLE( 4, 2)
        `ZKF_EXP2_TABLE( 5, 2)
        `ZKF_EXP2_TABLE( 6, 2)
        `ZKF_EXP2_TABLE( 7, 2)
        `ZKF_EXP2_TABLE( 8, 2)
        `ZKF_EXP2_TABLE( 9, 2)
        `ZKF_EXP2_TABLE(10, 2)
        `ZKF_EXP2_TABLE(11, 2)
        `ZKF_EXP2_TABLE(12, 2)
        `ZKF_EXP2_TABLE(13, 2)
        `ZKF_EXP2_TABLE(14, 2)
        `ZKF_EXP2_TABLE(15, 2)
        `ZKF_EXP2_TABLE(16, 2)
        `ZKF_EXP2_TABLE(17, 2)
        `ZKF_EXP2_TABLE(18, 2)
        `ZKF_EXP2_TABLE(19, 2)
        `ZKF_EXP2_TABLE(20, 3)
        `ZKF_EXP2_TABLE(21, 3)
        `ZKF_EXP2_TABLE(22, 3)
        `ZKF_EXP2_TABLE(23, 3)
        `ZKF_EXP2_TABLE(24, 3)
        `ZKF_EXP2_TABLE(25, 3)
        `ZKF_EXP2_TABLE(26, 3)
        `ZKF_EXP2_TABLE(27, 3)
        `ZKF_EXP2_TABLE(28, 3)
        `ZKF_EXP2_TABLE(29, 4)
        `ZKF_EXP2_TABLE(30, 4)
        `ZKF_EXP2_TABLE(31, 4)
        `ZKF_EXP2_TABLE(32, 4)
        `ZKF_EXP2_TABLE(33, 4)
        `ZKF_EXP2_TABLE(34, 4)
        `ZKF_EXP2_TABLE(35, 4)
        `ZKF_EXP2_TABLE(36, 4)
        `ZKF_EXP2_TABLE(37, 4)
        `ZKF_EXP2_TABLE(38, 5)
        `ZKF_EXP2_TABLE(39, 5)
        `ZKF_EXP2_TABLE(40, 5)
        `ZKF_EXP2_TABLE(41, 5)
        `ZKF_EXP2_TABLE(42, 5)
        `ZKF_EXP2_TABLE(43, 5)
        `ZKF_EXP2_TABLE(44, 5)
        `ZKF_EXP2_TABLE(45, 5)
        `ZKF_EXP2_TABLE(46, 5)
        `ZKF_EXP2_TABLE(47, 6)
        `ZKF_EXP2_TABLE(48, 6)
        `ZKF_EXP2_TABLE(49, 6)
        `ZKF_EXP2_TABLE(50, 6)
        `ZKF_EXP2_TABLE(51, 6)
        `ZKF_EXP2_TABLE(52, 6)
        `ZKF_EXP2_TABLE(53, 6)
        end else begin : g_unsupported
            _zkf_invalid_unsupported_table_wman u_invalid();  // run zkf_transcendental.py --emit
        end
    endgenerate
    `undef ZKF_EXP2_TABLE
    wire signed [WEU-1:0] e_i        = sb_out_e[SBW-1 -: WEU];
    wire                  e_finf     = sb_out_e[3];
    wire                  e_fzero    = sb_out_e[2];
    wire                  e_is_zero  = sb_out_e[1];
    wire                  e_lost     = sb_out_e[0];

    // For x == +0, 2**0 = 1.0 (exp_unbiased 0, significand 1.0, no GRS); otherwise 2**f * 2**i.
    wire signed [WEU-1:0] pack_exp = e_is_zero ? {WEU{1'b0}} : e_i;
    wire [WMAN-1:0]       pack_sig = e_is_zero ? {1'b1, {WFRAC{1'b0}}} : eval_sig;
    wire                  pack_g   = e_is_zero ? 1'b0 : eval_guard;
    wire                  pack_r   = e_is_zero ? 1'b0 : eval_round;
    wire                  pack_s   = e_is_zero ? 1'b0 : (eval_sticky | e_lost);

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEU), .STAGE_OUTPUT(STAGE_OUTPUT)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(ev_valid),
        .sign(1'b0),
        .force_zero(e_fzero),
        .force_inf(e_finf),
        .exp_unbiased(pack_exp),
        .significand(pack_sig),
        .guard(pack_g),
        .round(pack_r),
        .sticky(pack_s),
        .out_valid(out_valid),
        .y(y)
    );
endmodule

`default_nettype wire
