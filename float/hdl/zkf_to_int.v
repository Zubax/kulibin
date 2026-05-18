/// Streamed cast from Zubax Kulibin float to signed two's-complement integer with saturation.
/// The outputs are latched and are only valid when out_valid is asserted.
/// Register stages: 3 end-to-end.
///
/// +inf saturates to 2^(WINT-1)-1, -inf saturates to -2^(WINT-1), finite overflows saturate to the same bounds,
/// zero produces zero, and finite in-range values are round-to-nearest, ties-to-even.

`default_nettype none

module zkf_to_int #(
    parameter WEXP = 6,
    parameter WMAN = 18,
    parameter WINT = 32
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] a,

    output wire                   out_valid,
    output wire signed [WINT-1:0] y
);
    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4) || (WINT < 2)) begin : g_invalid
            _zkf_invalid_wexp_or_wman u_invalid();
        end
        // BIAS_INT and MAX_EXP_IN below use unsized integer shifts on WEXP, so WEXP > 31 would overflow Verilog's
        // 32-bit integer constant arithmetic and yield tool-dependent values.
        if (WEXP > 31) begin : g_invalid_wexp_too_wide
            _zkf_invalid_to_int_wexp_too_wide_unportable u_invalid();
        end
    endgenerate
    // verilator coverage_on

    localparam WFRAC   = WMAN - 1;
    localparam WFULL   = WEXP + WMAN;
    // Largest useful left shift before the result definitely overflows WINT signed bits.
    localparam LSH_MAX = (WINT > WMAN) ? (WINT - WMAN) : 0;
    localparam WLSH    = (LSH_MAX > 0) ? $clog2(LSH_MAX + 1) : 1;
    localparam WLEFT   = WMAN + LSH_MAX;
    // Largest useful right shift before everything becomes sticky.
    localparam RSH_MAX = WMAN + 2;
    localparam WRSH    = $clog2(RSH_MAX + 1);
    // Working magnitude width: enough to detect overflow against INT_NEG_MAG (= 2^(WINT-1)).
    localparam WMAG    = ((WINT + 1) > (WLEFT + 1)) ? (WINT + 1) : (WLEFT + 1);

    // Folded shift-magnitude and predicate thresholds in integer arithmetic so widths can be sized from them rather
    // than from WEXP alone.
    //   LEFT_SHIFT_BASE  : exp_in == this means value == 2^WFRAC, the boundary between right and left shift.
    //                      left_shift_full = exp_in - LEFT_SHIFT_BASE.
    //   LEFT_OVER_BASE   : exp_in >= this guarantees the value overflows WINT signed bits even before rounding
    //                      (saturation will fire downstream).
    //   RIGHT_OVER_BASE  : exp_in < this means the right shift amount exceeds RSH_MAX, so the shifter would not
    //                      capture any useful bits and we clamp to RSH_MAX.
    localparam integer BIAS_INT         = (1 << (WEXP - 1)) - 1;
    localparam integer LEFT_SHIFT_BASE  = BIAS_INT + WFRAC;
    localparam integer LEFT_OVER_BASE   = LEFT_SHIFT_BASE + LSH_MAX + 1;
    localparam integer RIGHT_OVER_BASE  = LEFT_SHIFT_BASE - RSH_MAX;
    // WEU sizes the two wide subtractions left_shift_full and right_shift_full.
    // left_shift_full = exp_in - LEFT_SHIFT_BASE spans [-LEFT_SHIFT_BASE, MAX_EXP_IN - LEFT_SHIFT_BASE], and
    // right_shift_full = LEFT_SHIFT_BASE - exp_in is its negation, so the largest absolute value across both is
    // max(LEFT_SHIFT_BASE, MAX_EXP_IN - LEFT_SHIFT_BASE). When MAX_EXP_IN < LEFT_SHIFT_BASE (typical wide-WMAN)
    // the second term is negative and LEFT_SHIFT_BASE dominates.
    localparam integer MAX_EXP_IN    = (1 << WEXP) - 1;
    localparam integer MAX_POS_DELTA = MAX_EXP_IN - LEFT_SHIFT_BASE;
    localparam integer MAX_ABS_DELTA = (LEFT_SHIFT_BASE > MAX_POS_DELTA) ? LEFT_SHIFT_BASE : MAX_POS_DELTA;
    // clog2(N+1)+1 is the minimum signed width that holds [-N,N-1]. WMAN >= 4 forces LEFT_SHIFT_BASE >= 2^(WEXP-1)+2,
    // so this also guarantees WEU >= WEXP + 1, which the exp_in_ext zero-extension below needs.
    localparam integer WEU           = $clog2(MAX_ABS_DELTA + 1) + 1;

    // WEU was sized so LEFT_SHIFT_BASE fits in (WEU-1) unsigned bits.
    localparam signed [WEU-1:0] LEFT_SHIFT_BASE_EXT = $signed({1'b0, LEFT_SHIFT_BASE[WEU-2:0]});
    localparam signed [WEU-1:0] LEFT_SHIFT_OFFSET   = -LEFT_SHIFT_BASE_EXT;

    // -- Combinational decode.
    wire             sign_in = a[WFULL-1];
    wire [WEXP-1:0]  exp_in  = a[WFULL-2:WFRAC];
    wire [WFRAC-1:0] frac_in = a[WFRAC-1:0];
    wire             is_zero = ~|exp_in;
    wire             is_inf  =  &exp_in;
    // The hidden bit is implicit for normal values. For zero inputs the right shifter cannot always saturate enough
    // to wipe the hidden bit (BIAS + WFRAC can be less than WMAN + 2 for small WEXP), so explicitly zero the
    // significand here; the downstream pipeline then yields mag_rounded = 0 without a separate is_zero late-stage mux.
    wire [WMAN-1:0]  sig_in  = is_zero ? {WMAN{1'b0}} : {1'b1, frac_in};

    wire signed [WEU-1:0] exp_in_ext = $signed({{(WEU-WEXP){1'b0}}, exp_in});

    // Two parallel folded-constant subtractions provide the shift magnitudes (only their low WLSH / WRSH bits are
    // consumed downstream). right_shift_full uses the positive constant directly rather than negating left_shift_full,
    // which would put both shift amounts on the same serial carry chain.
    wire signed [WEU-1:0] left_shift_full  = exp_in_ext + LEFT_SHIFT_OFFSET;
    wire signed [WEU-1:0] right_shift_full = LEFT_SHIFT_BASE_EXT - exp_in_ext;

    // The three predicates are unsigned comparisons of exp_in against compile-time non-negative constants. When a
    // constant lies outside the unsigned exp_in range (e.g. very wide WMAN pushes LEFT_SHIFT_BASE above 2^WEXP-1),
    // the comparison resolves at elaboration and emits no runtime logic. When it fits inside exp_in's width,
    // yosys/abc realises the compare as a shallow LUT tree on the carry chain rather than a wide signed subtract,
    // so the predicate does not chain a WEU-bit CCU2 stack onto the critical path feeding the shifter mux.
    //
    // right_too_big already implies ~is_left_shift: RIGHT_OVER_BASE = LEFT_SHIFT_BASE - RSH_MAX < LEFT_SHIFT_BASE
    // (RSH_MAX=WMAN+2>0), so exp_in<RIGHT_OVER_BASE necessarily means exp_in<LEFT_SHIFT_BASE, i.e., is_left_shift=0.
    wire is_left_shift;
    wire left_too_big;
    wire right_too_big;
    wire [WRSH-1:0] rshamt_clamped = right_too_big ? RSH_MAX[WRSH-1:0] : right_shift_full[WRSH-1:0];
    wire [WLSH-1:0] lshamt_clamped = (is_left_shift && !left_too_big) ? left_shift_full[WLSH-1:0] : {WLSH{1'b0}};

    generate
        if (LEFT_SHIFT_BASE > MAX_EXP_IN) begin : g_lshift_never
            assign is_left_shift = 1'b0;
        end else begin : g_lshift_cmp
            assign is_left_shift = exp_in >= LEFT_SHIFT_BASE[WEXP-1:0];
        end

        if (LEFT_OVER_BASE > MAX_EXP_IN) begin : g_lover_never
            assign left_too_big = 1'b0;
        end else begin : g_lover_cmp
            assign left_too_big = exp_in >= LEFT_OVER_BASE[WEXP-1:0];
        end

        if (RIGHT_OVER_BASE <= 0) begin : g_rover_never
            assign right_too_big = 1'b0;
        end else if (RIGHT_OVER_BASE > MAX_EXP_IN) begin : g_rover_always
            assign right_too_big = 1'b1;
        end else begin : g_rover_cmp
            assign right_too_big = exp_in < RIGHT_OVER_BASE[WEXP-1:0];
        end
    endgenerate

    // Apply the barrel shifters before stage 1 so the heavy mux trees ride the input cone instead of chaining behind
    // a register; the rounding adder and saturation logic then have a shallow combinational cone after stage 1.
    wire [WMAN+1:0] rsh_out_pre;
    _zkf_to_int_rshift #(.W(WMAN + 2)) u_rshift (
        .x({sig_in, 2'b00}),
        .shamt(rshamt_clamped),
        .y(rsh_out_pre)
    );

    wire  [WMAN-1:0] rsh_mag_pre    = rsh_out_pre[WMAN+1:2];
    wire             rsh_guard_pre  = rsh_out_pre[1];
    wire             rsh_sticky_pre = rsh_out_pre[0];
    wire [WLEFT-1:0] lsh_out_pre;
    generate
        if (LSH_MAX > 0) begin : g_lshift
            assign lsh_out_pre = {{LSH_MAX{1'b0}}, sig_in} << lshamt_clamped;
        end else begin : g_no_lshift
            assign lsh_out_pre = sig_in;
        end
    endgenerate

    wire [WMAG-1:0] mag_pre_rsh_in = {{(WMAG-WMAN){1'b0}}, rsh_mag_pre};
    wire [WMAG-1:0] mag_pre_lsh_in = {{(WMAG-WLEFT){1'b0}}, lsh_out_pre};
    wire [WMAG-1:0] mag_pre_in     = is_left_shift ? mag_pre_lsh_in : mag_pre_rsh_in;

    wire guard_in  = is_left_shift ? 1'b0 : rsh_guard_pre;
    wire sticky_in = is_left_shift ? 1'b0 : rsh_sticky_pre;

    // -- Stage 1: capture post-shift state. Reset only validity; payload free-runs.
    reg             s1_valid;
    reg             s1_sign;
    reg             s1_is_inf;
    reg             s1_left_too_big;
    reg [WMAG-1:0]  s1_mag_pre;
    reg             s1_guard;
    reg             s1_sticky;

    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= in_valid;
        end
        s1_sign         <= sign_in;
        s1_is_inf       <= is_inf;
        s1_left_too_big <= left_too_big;
        s1_mag_pre      <= mag_pre_in;
        s1_guard        <= guard_in;
        s1_sticky       <= sticky_in;
    end

    // -- Stage 1 -> Stage 2 combinational: round, then saturation detect via bit-range checks.
    // Round only the low WINT bits — those are all that ever leaves this module — and feed any bit above WINT-1 into
    // hi_pre in parallel. This caps the carry chain at WINT+1 bits even when WMAN > WINT (where mag_pre is much wider)
    // and keeps the rounding adder off the critical path that wider configurations expose.
    wire           round_increment = s1_guard & (s1_sticky | s1_mag_pre[0]);
    wire           hi_pre          = |s1_mag_pre[WMAG-1:WINT];
    wire [WINT:0]  mag_rounded_low = {1'b0, s1_mag_pre[WINT-1:0]} + {{WINT{1'b0}}, round_increment};
    wire           rcarry          = mag_rounded_low[WINT];

    // Saturation detection. Positive overflow fires when mag > INT_MAX = 2^(WINT-1)-1, i.e. any bit at position WINT-1
    // or above is set. Negative overflow fires when mag > 2^(WINT-1) (the magnitude 2^(WINT-1) itself is valid: it
    // negates exactly to INT_MIN), i.e. any bit above WINT-1 is set OR (bit WINT-1 is set AND some lower bit is set).
    // hi_pre OR rcarry covers every set bit at or above position WINT regardless of whether it pre-existed in mag_pre
    // or appeared as the rounding carry-out, including the case where the round ripple turns a hi_pre-clear value into
    // an overflowing one.
    wire hi_set  = hi_pre | rcarry;
    wire top_bit =  mag_rounded_low[WINT-1];
    wire low_set = |mag_rounded_low[WINT-2:0];

    wire overflow_pos = hi_set | top_bit;
    wire overflow_neg = hi_set | (top_bit & low_set);
    wire overflow_now = s1_is_inf | s1_left_too_big | (s1_sign ? overflow_neg : overflow_pos);

    // Saturation magnitudes (as unsigned WINT bits). INT_NEG_MAG (= 0x80..0) negates back to INT_MIN.
    localparam [WINT-1:0] INT_NEG_MAG = {1'b1, {(WINT-1){1'b0}}};
    localparam [WINT-1:0] INT_MAX     = {1'b0, {(WINT-1){1'b1}}};

    wire [WINT-1:0] mag_sat_overflow = s1_sign ? INT_NEG_MAG : INT_MAX;
    wire [WINT-1:0] mag_sat          = overflow_now ? mag_sat_overflow : mag_rounded_low[WINT-1:0];

    // -- Stage 2 register.
    reg            s2_valid;
    reg            s2_sign;
    reg [WINT-1:0] s2_mag_sat;

    always @(posedge clk) begin
        if (rst) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
        end
        s2_sign    <= s1_sign;
        s2_mag_sat <= mag_sat;
    end

    // -- Stage 2 -> Stage 3: apply sign by two's-complement negation.
    wire [WINT-1:0] y_pre_unsigned = s2_sign ? (~s2_mag_sat + {{(WINT-1){1'b0}}, 1'b1}) : s2_mag_sat;

    // -- Stage 3 register (output).
    reg                   s3_valid;
    reg signed [WINT-1:0] s3_y;

    always @(posedge clk) begin
        if (rst) begin
            s3_valid <= 1'b0;
        end else begin
            s3_valid <= s2_valid;
        end
        s3_y <= $signed(y_pre_unsigned);
    end

    assign out_valid = s3_valid;
    assign y         = s3_y;
endmodule


// Sticky-folded right-shift barrel. Bit 0 of the output OR-collects the input's bit 0 with every bit that falls off,
// so a single combined sticky bit feeds the rounding logic instead of an expensive wide OR-reduction outside the
// shifter. Caller must clamp shamt so that shamt <= W (this module's only consumer in zkf_to_int clamps via
// rshamt_clamped); beyond that point the stage-internal logic naturally produces zero magnitude with sticky = |x,
// which is the desired behaviour for our integer-cast use.
module _zkf_to_int_rshift #(parameter W = 20) (
    input  wire           [W-1:0] x,
    input  wire [$clog2(W+1)-1:0] shamt,
    output wire           [W-1:0] y
);
    localparam WLOCAL = $clog2(W + 1);
    wire [((WLOCAL + 1) * W)-1:0] data_stage;
    wire           [WLOCAL:0]     sticky_stage;

    assign data_stage[0 +: W] = x;
    assign sticky_stage[0]    = 1'b0;

    genvar i_stage;
    generate
        for (i_stage = 0; i_stage < WLOCAL; i_stage = i_stage + 1) begin : g_stage
            localparam integer DIST = 1 << i_stage;
            wire [W-1:0] data_in;
            wire [W-1:0] shifted;
            wire         lost;
            assign data_in = data_stage[i_stage * W +: W];
            if (DIST >= W) begin : g_saturating
                assign shifted = {W{1'b0}};
                assign lost    = |data_in;
            end else begin : g_in_range
                assign shifted = {{DIST{1'b0}}, data_in[W-1:DIST]};
                assign lost    = |data_in[DIST-1:0];
            end
            assign data_stage[(i_stage + 1) * W +: W] = shamt[i_stage] ? shifted : data_in;
            assign sticky_stage[i_stage + 1]          = sticky_stage[i_stage] | (shamt[i_stage] & lost);
        end
    endgenerate

    assign y = {data_stage[(WLOCAL * W) + W - 1 : (WLOCAL * W) + 1],
                data_stage[WLOCAL * W] | sticky_stage[WLOCAL]};
endmodule

`default_nettype wire
