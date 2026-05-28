/// Streamed base-2 logarithm for the Zubax Kulibin float format: y = log2(x).
/// Register stages: STAGE_INPUT + 6 + STAGE_PRODUCT + STAGE_NORMALIZE + D*(2+STAGE_PRODUCT) + STAGE_OUTPUT,
/// where D depends on WMAN per the table below.
/// Zero-bubble, throughput-1, no backpressure.
/// Behavior:
///
///   log2(finite>0) = log2(x), round-to-nearest ties-to-even
///   log2(+inf)     = +inf
///   log2(+0)       = -inf, pole=1
///   log2(x<0)      = -inf, domain_error=1
///
/// Algorithm:
///
///  1. With x = m * 2^e (m = 1.frac in [1,2), e = exp-BIAS), log2(x) = e + log2(m).
///
///  2. The pipelined per-WMAN table+polynomial core selected by the generate-if (_zkf_log2_m<WMAN>_d<D>) evaluates
///     log2(m) = t*P(t) (t = stored fraction) as a fixed-point fraction in [0,1), factoring out the exact t for full
///     relative accuracy near m == 1.
///
///  3. The signed fixed-point sum R = e + log2(m) is renormalized with _zkf_normshift and rounded by _zkf_pack.
///     Results are always representable for finite x, so no overflow path is needed.
///
/// STAGE_PRODUCT={0,1} splits the Horner multiply for timing closure (like zkf_mul).
/// STAGE_OUTPUT={0,1} registers the output.

`default_nettype none

module zkf_log2 #(
    parameter WEXP            = 6,    // exponent field width
    parameter WMAN            = 18,   // significand precision including the hidden bit
    parameter STAGE_INPUT     = 0,    // 0: combinational inputs;   1: latch inputs before any logic (+1 stage)
    parameter STAGE_PRODUCT   = 0,    // 0: single Horner multiply; 1: 2x2 split (+1 stage/deg); 2: 3x3 split (+2/deg)
    parameter STAGE_NORMALIZE = 0,    // 0: single normalizer barrier; 1: extra top barrier (+1 stage)
    parameter STAGE_OUTPUT    = 0     // 0: combinational outputs;     1: registered outputs, +1 stage
) (
    input wire clk,
    input wire rst,

    input wire                 in_valid,
    input wire [WEXP+WMAN-1:0] x,

    output wire                 out_valid,
    output wire [WEXP+WMAN-1:0] y,
    output wire                 domain_error,
    output wire                 pole
);
    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wman
            _zkf_invalid_wexp_or_wman u_invalid();
        end
        // BIAS below uses an unsized integer shift on WEXP; WEXP >= 31 would overflow 32-bit integer constants.
        if (WEXP >= 31) begin : g_invalid_wexp_too_wide
            _zkf_invalid_log2_wexp_too_wide_unportable u_invalid();
        end
    endgenerate
    // verilator coverage_on

    localparam WFRAC = WMAN - 1;
    localparam WFULL = WEXP + WMAN;
    // CF/F2: MUST match the generator's GUARD_CF (float/zkf_transcendental.py). F2 = WFRAC + CF.
    localparam CF     = WMAN + 12;
    localparam F2     = WFRAC + CF;             // fractional bits of log2(1+t) and of the R accumulator
    localparam WNORM  = WEXP + F2 + 1;          // magnitude width fed to the normalizer
    localparam WR     = WNORM + 1;              // signed R = e + log2(m) width
    localparam WIDX   = $clog2(WNORM);          // normalize shift-count width
    localparam WE     = WEXP + 1;               // signed e = exp - BIAS
    // Signed unbiased result exponent in [-F2, WEXP-1]; also kept >= WEXP+2 because _zkf_pack requires its
    // exponent field to be at least WEXP+1 bits wide for its internal bias arithmetic.
    localparam WEU_RAW = $clog2(F2 + 1) + 2;
    localparam WEU     = (WEU_RAW > (WEXP + 2)) ? WEU_RAW : (WEXP + 2);
    localparam SBW     = WE + 4;                // evaluator sideband: {e, is_special, special_sign, pole, de}

    localparam integer BIAS = (1 << (WEXP - 1)) - 1;

    // -- Optional input register stage (latch x ahead of the decode/evaluator cone).
    wire             in_valid_q;
    wire [WFULL-1:0] x_q;
    _zkf_pipe #(.W(WFULL), .N(STAGE_INPUT ? 1 : 0)) u_input_pipe (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in(x), .out_valid(in_valid_q), .out(x_q)
    );

    // -- Decode and classify.
    wire             sign_in = x_q[WFULL-1];
    wire [WEXP-1:0]  exp_in  = x_q[WFULL-2:WFRAC];
    wire [WFRAC-1:0] frac_in = x_q[WFRAC-1:0];
    wire             is_zero = ~|exp_in;
    wire             is_inf  =  &exp_in;
    // Special results are all +/-inf: +inf for +inf input; -inf for +0 (pole), negative finite, or -inf (domain).
    wire             is_special_in   = is_inf | is_zero | sign_in;
    wire             special_sign_in = is_zero | sign_in;          // 0 -> +inf, 1 -> -inf
    wire             pole_in         = is_zero;
    wire             de_in           = sign_in & ~is_zero;
    // verilator coverage_off
    wire signed [WE-1:0] e_in = $signed({1'b0, exp_in}) - $signed(BIAS[WE-1:0]);
    // verilator coverage_on

    // -- Pipelined evaluator: log2(m) = t*P(t). e and the special-case flags ride the sideband, aligned to l_fix.
    wire [SBW-1:0] sb_in_l = {e_in, is_special_in, special_sign_in, pole_in, de_in};
    wire           ev_valid;
    wire [SBW-1:0] sb_out_l;
    wire [F2-1:0]  l_fix;
    // The D arguments are the closed-form degree(WMAN); a stale value would name a now-missing module and fail loudly.
    `define ZKF_LOG2_TABLE(W, D) end else if (WMAN == W) begin : g_m``W \
        _zkf_log2_m``W``_d``D #(.SBW(SBW), .STAGE_PRODUCT(STAGE_PRODUCT)) u_eval ( \
            .clk(clk), .rst(rst), .in_valid(in_valid_q), .sb_in(sb_in_l), .frac(frac_in), \
            .out_valid(ev_valid), .sb_out(sb_out_l), .l_fix(l_fix));
    generate
        if (1'b0) begin : g_none  // seed: the macro opens with "end else if", so every table line is uniform
        `ZKF_LOG2_TABLE( 4, 5)
        `ZKF_LOG2_TABLE( 5, 4)
        `ZKF_LOG2_TABLE( 6, 3)
        `ZKF_LOG2_TABLE( 7, 2)
        `ZKF_LOG2_TABLE( 8, 2)
        `ZKF_LOG2_TABLE( 9, 2)
        `ZKF_LOG2_TABLE(10, 2)
        `ZKF_LOG2_TABLE(11, 2)
        `ZKF_LOG2_TABLE(12, 2)
        `ZKF_LOG2_TABLE(13, 2)
        `ZKF_LOG2_TABLE(14, 2)
        `ZKF_LOG2_TABLE(15, 2)
        `ZKF_LOG2_TABLE(16, 2)
        `ZKF_LOG2_TABLE(17, 2)
        `ZKF_LOG2_TABLE(18, 2)
        `ZKF_LOG2_TABLE(19, 2)
        `ZKF_LOG2_TABLE(20, 3)
        `ZKF_LOG2_TABLE(21, 3)
        `ZKF_LOG2_TABLE(22, 3)
        `ZKF_LOG2_TABLE(23, 3)
        `ZKF_LOG2_TABLE(24, 3)
        `ZKF_LOG2_TABLE(25, 3)
        `ZKF_LOG2_TABLE(26, 3)
        `ZKF_LOG2_TABLE(27, 3)
        `ZKF_LOG2_TABLE(28, 3)
        `ZKF_LOG2_TABLE(29, 4)
        `ZKF_LOG2_TABLE(30, 4)
        `ZKF_LOG2_TABLE(31, 4)
        `ZKF_LOG2_TABLE(32, 4)
        `ZKF_LOG2_TABLE(33, 4)
        `ZKF_LOG2_TABLE(34, 4)
        `ZKF_LOG2_TABLE(35, 4)
        `ZKF_LOG2_TABLE(36, 4)
        `ZKF_LOG2_TABLE(37, 4)
        `ZKF_LOG2_TABLE(38, 5)
        `ZKF_LOG2_TABLE(39, 5)
        `ZKF_LOG2_TABLE(40, 5)
        `ZKF_LOG2_TABLE(41, 5)
        `ZKF_LOG2_TABLE(42, 5)
        `ZKF_LOG2_TABLE(43, 5)
        `ZKF_LOG2_TABLE(44, 5)
        `ZKF_LOG2_TABLE(45, 5)
        `ZKF_LOG2_TABLE(46, 5)
        `ZKF_LOG2_TABLE(47, 6)
        `ZKF_LOG2_TABLE(48, 6)
        `ZKF_LOG2_TABLE(49, 6)
        `ZKF_LOG2_TABLE(50, 6)
        `ZKF_LOG2_TABLE(51, 6)
        `ZKF_LOG2_TABLE(52, 6)
        `ZKF_LOG2_TABLE(53, 6)
        end else begin : g_unsupported
            _zkf_invalid_unsupported_table_wman u_invalid();  // run float/zkf_transcendental.py --emit
        end
    endgenerate
    `undef ZKF_LOG2_TABLE
    wire signed [WE-1:0] e_o       = sb_out_l[SBW-1 -: WE];
    wire                 e_special = sb_out_l[3];
    wire                 e_ssign   = sb_out_l[2];
    wire                 e_pole    = sb_out_l[1];
    wire                 e_de      = sb_out_l[0];

    // -- R = e + log2(m), as a signed fixed-point value; take its magnitude for normalization.
    // verilator coverage_off
    wire signed [WR-1:0] e_ext  = {{(WR-WE){e_o[WE-1]}}, e_o};
    wire signed [WR-1:0] r_val  = (e_ext <<< F2) + $signed({{(WR-F2){1'b0}}, l_fix});
    wire                 r_sign = r_val[WR-1];
    wire        [WR-1:0] r_abs  = r_sign ? (~r_val + {{(WR-1){1'b0}}, 1'b1}) : r_val;
    wire     [WNORM-1:0] mag    = r_abs[WNORM-1:0];
    // verilator coverage_on

    // -- Stage P1: register the magnitude and the sideband ahead of the (split) normalizer.
    reg                  p1_valid;
    // verilator coverage_off
    reg      [WNORM-1:0] p1_mag;
    // verilator coverage_on
    reg                  p1_sign;
    reg                  p1_special;
    reg                  p1_ssign;
    reg                  p1_pole;
    reg                  p1_de;
    always @(posedge clk) begin
        if (rst) p1_valid <= 1'b0;
        else     p1_valid <= ev_valid;
        p1_mag     <= mag;
        p1_sign    <= r_sign;
        p1_special <= e_special;
        p1_ssign   <= e_ssign;
        p1_pole    <= e_pole;
        p1_de      <= e_de;
    end

    // Normalizer with internal register barriers.
    wire              norm_zero;
    wire [WIDX-1:0]   norm_count;
    // verilator coverage_off
    wire [WNORM-1:0]  norm_aligned;
    // verilator coverage_on
    _zkf_normshift #(.W(WNORM), .STAGE_SPLIT(1 + STAGE_NORMALIZE)) u_norm (
        .clk(clk),
        .x(p1_mag),
        .zero(norm_zero),
        .count(norm_count),
        .y(norm_aligned)
    );

    // -- Stage P1b: delay the sideband (1 + STAGE_NORMALIZE) cycles to line up with the normalizer's output.
    localparam P1B_W = 5;  // {sign, special, ssign, pole, de}
    wire             p1b_valid;
    wire [P1B_W-1:0] p1b_sb;
    _zkf_pipe #(.W(P1B_W), .N(1 + STAGE_NORMALIZE)) u_p1b (
        .clk(clk), .rst(rst),
        .in_valid(p1_valid),
        .in({p1_sign, p1_special, p1_ssign, p1_pole, p1_de}),
        .out_valid(p1b_valid),
        .out(p1b_sb)
    );
    wire p1b_sign    = p1b_sb[4];
    wire p1b_special = p1b_sb[3];
    wire p1b_ssign   = p1b_sb[2];
    wire p1b_pole    = p1b_sb[1];
    wire p1b_de      = p1b_sb[0];

    wire [WMAN-1:0] norm_sig    =  norm_aligned[WNORM-1 -: WMAN];
    wire            norm_guard  =  norm_aligned[WNORM-WMAN-1];
    wire            norm_round  =  norm_aligned[WNORM-WMAN-2];
    wire            norm_sticky = |norm_aligned[WNORM-WMAN-3:0];
    // Result exponent (unbiased) = leading-one position - F2 = ((WNORM-1) - count) - F2.
    // verilator coverage_off
    wire signed [WEU-1:0] exp_unbiased = $signed((WNORM - 1 - F2)) - $signed({{(WEU-WIDX){1'b0}}, norm_count});
    // verilator coverage_on
    wire pack_force_inf  = p1b_special;
    wire pack_force_zero = ~p1b_special & norm_zero;   // R == 0 (x == 1.0) -> +0
    wire pack_sign       = p1b_special ? p1b_ssign : p1b_sign;

    // -- Stage P2: register the packer inputs, isolating the normalizer's second half from the rounder.
    reg                  p2_valid;
    reg                  p2_sign;
    reg                  p2_force_inf;
    reg                  p2_force_zero;
    reg signed [WEU-1:0] p2_exp;
    reg        [WMAN-1:0] p2_sig;
    reg                  p2_guard;
    reg                  p2_round;
    reg                  p2_sticky;
    reg                  p2_de;
    reg                  p2_pole;
    always @(posedge clk) begin
        if (rst) p2_valid <= 1'b0;
        else     p2_valid <= p1b_valid;
        p2_sign       <= pack_sign;
        p2_force_inf  <= pack_force_inf;
        p2_force_zero <= pack_force_zero;
        p2_exp        <= exp_unbiased;
        p2_sig        <= norm_sig;
        p2_guard      <= norm_guard;
        p2_round      <= norm_round;
        p2_sticky     <= norm_sticky;
        p2_de         <= p1b_de;
        p2_pole       <= p1b_pole;
    end

    _zkf_pack #(.WEXP(WEXP), .WMAN(WMAN), .WEXP_UNBIASED(WEU), .STAGE_OUTPUT(STAGE_OUTPUT)) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(p2_valid),
        .sign(p2_sign),
        .force_zero(p2_force_zero),
        .force_inf(p2_force_inf),
        .exp_unbiased(p2_exp),
        .significand(p2_sig),
        .guard(p2_guard),
        .round(p2_round),
        .sticky(p2_sticky),
        .out_valid(out_valid),
        .y(y)
    );

    // Carry domain_error/pole through the same output stage as the packer so they land with out_valid.
    _zkf_pack_delay #(.W(2), .STAGE_OUTPUT(STAGE_OUTPUT)) u_flags (
        .clk(clk), .rst(rst), .x({p2_de, p2_pole}), .y({domain_error, pole})
    );
endmodule

`default_nettype wire
