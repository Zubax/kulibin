/// Streamed base-2 logarithm for the Zubax Kulibin float format: y = log2(x).
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
///  2. The pipelined per-WMAN table+polynomial core selected by the generate-if evaluates log2(m) = t*P(t)
///     (t = stored fraction) as a fixed-point fraction in [0,1), factoring out the exact t for full relative
///     accuracy near m == 1.
///
///  3. The signed fixed-point sum R = e + log2(m) is renormalized and rounded by _zkf_fixed_to_float, which owns the
///     _zkf_normshift instance, the GRS extraction, the exp_unbiased arithmetic, the optional packer input register,
///     and the _zkf_pack output stage. Results are always representable for finite x, so no overflow path is needed.
///
/// STAGE_PRODUCT={0,1,2} splits the Horner multiply for timing closure (like zkf_mul).
/// STAGE_NORMALIZE={0,1,2} forwards directly to _zkf_normshift.STAGE_SPLIT.
/// STAGE_PACK={0,1} forwards to _zkf_pack.STAGE_INPUT (insulates rounder from normshift cone).
/// STAGE_OUTPUT={0,1} registers the output.

`default_nettype none

`define ZKF_LOG2_DEGREE (((WMAN+16)/9)-1)
`define ZKF_LOG2_LATENCY \
    (STAGE_INPUT + 5 + STAGE_PRODUCT + STAGE_NORMALIZE + STAGE_PACK \
     + `ZKF_LOG2_DEGREE*(2+STAGE_PRODUCT) + STAGE_OUTPUT)

module zkf_log2 #(
    parameter WEXP            = 6,    // exponent field width
    parameter WMAN            = 18,   // significand precision including the hidden bit
    parameter STAGE_INPUT     = 0,    // 0: combinational inputs;   1: latch inputs before any logic (+1 stage)
    parameter STAGE_PRODUCT   = 0,    // 0: single Horner multiply; 1: 2x2 split (+1 stage/deg); 2: 3x3 split (+2/deg)
    parameter STAGE_NORMALIZE = 0,    // 0/1/2 internal normshift barriers (direct -> _zkf_normshift.STAGE_SPLIT)
    parameter STAGE_PACK      = 0,    // 0: comb pack input; 1: register pack input (insulates rounder from normshift)
    parameter STAGE_OUTPUT    = 0,    // 0: combinational outputs;     1: registered outputs, +1 stage
    parameter LATENCY         = `ZKF_LOG2_LATENCY   // must equal the register-stage count; checked below
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
        if (LATENCY != `ZKF_LOG2_LATENCY) begin : g_invalid_latency
            _zkf_invalid_latency_mismatch u_invalid();
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
    zkf_pipe #(.W(WFULL), .N(STAGE_INPUT ? 1 : 0)) u_input_pipe (
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
    // We pass the closed-form degree D below; the core asserts it matches the degree its ROM was fitted for (mirrors
    // the LATENCY parameter), so the Horner depth / latency cannot drift. A WMAN without a pre-generated table names a
    // now-missing module and fails loudly.
    `define ZKF_LOG2_TABLE(W) end else if (WMAN == W) begin : g_m``W \
        _zkf_log2_m``W #(.D(`ZKF_LOG2_DEGREE), .SBW(SBW), .STAGE_PRODUCT(STAGE_PRODUCT)) u_eval ( \
            .clk(clk), .rst(rst), .in_valid(in_valid_q), .sb_in(sb_in_l), .frac(frac_in), \
            .out_valid(ev_valid), .sb_out(sb_out_l), .l_fix(l_fix));
    generate
        if (1'b0) begin : g_none  // seed: the macro opens with "end else if", so every table line is uniform
        `ZKF_LOG2_TABLE(11)
        `ZKF_LOG2_TABLE(12)
        `ZKF_LOG2_TABLE(13)
        `ZKF_LOG2_TABLE(14)
        `ZKF_LOG2_TABLE(15)
        `ZKF_LOG2_TABLE(16)
        `ZKF_LOG2_TABLE(17)
        `ZKF_LOG2_TABLE(18)
        `ZKF_LOG2_TABLE(19)
        `ZKF_LOG2_TABLE(20)
        `ZKF_LOG2_TABLE(21)
        `ZKF_LOG2_TABLE(22)
        `ZKF_LOG2_TABLE(23)
        `ZKF_LOG2_TABLE(24)
        `ZKF_LOG2_TABLE(25)
        `ZKF_LOG2_TABLE(26)
        `ZKF_LOG2_TABLE(27)
        `ZKF_LOG2_TABLE(28)
        `ZKF_LOG2_TABLE(29)
        `ZKF_LOG2_TABLE(30)
        `ZKF_LOG2_TABLE(31)
        `ZKF_LOG2_TABLE(32)
        `ZKF_LOG2_TABLE(33)
        `ZKF_LOG2_TABLE(34)
        `ZKF_LOG2_TABLE(35)
        `ZKF_LOG2_TABLE(36)
        `ZKF_LOG2_TABLE(37)
        `ZKF_LOG2_TABLE(38)
        `ZKF_LOG2_TABLE(39)
        `ZKF_LOG2_TABLE(40)
        `ZKF_LOG2_TABLE(41)
        `ZKF_LOG2_TABLE(42)
        `ZKF_LOG2_TABLE(43)
        `ZKF_LOG2_TABLE(44)
        `ZKF_LOG2_TABLE(45)
        `ZKF_LOG2_TABLE(46)
        `ZKF_LOG2_TABLE(47)
        `ZKF_LOG2_TABLE(48)
        `ZKF_LOG2_TABLE(49)
        `ZKF_LOG2_TABLE(50)
        `ZKF_LOG2_TABLE(51)
        `ZKF_LOG2_TABLE(52)
        `ZKF_LOG2_TABLE(53)
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

    // Resolve the final sign at the P1 input: when the evaluator flagged a special result (+/-inf), the resolved
    // sign is the special-case sign carried in the sideband; otherwise it is the sign of R = e + log2(m).
    wire resolved_sign = e_special ? e_ssign : r_sign;

    // -- Stage P1: register the magnitude, the resolved sign, and the special-case sideband ahead of the
    // _zkf_fixed_to_float helper. Reset only validity; payload free-runs.
    reg                  p1_valid;
    // verilator coverage_off
    reg      [WNORM-1:0] p1_mag;
    // verilator coverage_on
    reg                  p1_sign;
    reg                  p1_special;
    reg                  p1_pole;
    reg                  p1_de;
    always @(posedge clk) begin
        if (rst) p1_valid <= 1'b0;
        else     p1_valid <= ev_valid;
        p1_mag     <= mag;
        p1_sign    <= resolved_sign;
        p1_special <= e_special;
        p1_pole    <= e_pole;
        p1_de      <= e_de;
    end

    // -- Normalize, combine, and pack via the shared back-end. The helper owns the _zkf_normshift instance
    // (STAGE_SPLIT = 1 + STAGE_NORMALIZE), the GRS extraction, exp_unbiased = (WNORM-1-F2) - shamt, the optional P2
    // pack-input register (STAGE_PACK_INPUT=1 since zkf_log2 needs the extra cycle for fmax closure), and the
    // _zkf_pack output. The pole / domain_error flags ride the SB_W=2 sideband and emerge in lockstep with y.
    wire [1:0] sb_out_flags;
    _zkf_fixed_to_float #(
        .WEXP(WEXP), .WMAN(WMAN),
        .WMAG(WNORM), .WEU(WEU),
        .EXP_OFFSET(WNORM - 1 - F2),
        .EXP_IS_BIASED(0),
        .ASSUME_NO_OVERFLOW(1),  // log2(finite>0) is always representable, disable overflow detection circuit
        .SB_W(2),
        .STAGE_NORMALIZE(STAGE_NORMALIZE),
        .STAGE_PACK(STAGE_PACK),
        .STAGE_OUTPUT(STAGE_OUTPUT)
    ) u_fixed_to_float (
        .clk(clk), .rst(rst),
        .in_valid(p1_valid),
        .sign(p1_sign),
        .force_inf(p1_special),
        .mag(p1_mag),
        .sb_in({p1_pole, p1_de}),
        .out_valid(out_valid),
        .y(y),
        .sb_out(sb_out_flags)
    );
    assign pole         = sb_out_flags[1];
    assign domain_error = sb_out_flags[0];
endmodule

`undef ZKF_LOG2_LATENCY
`undef ZKF_LOG2_DEGREE
`default_nettype wire
