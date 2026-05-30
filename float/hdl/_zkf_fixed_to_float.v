/// Streamed signed-magnitude fixed-point -> normalized float.
/// Internalizes the _zkf_normshift + sideband delay + pack-input combine + _zkf_pack pipeline. The caller forms the
/// unsigned magnitude (and registers it), resolves the special-case sign and force_inf ahead of the helper, and passes
/// generic sideband through sb_in / sb_out for outputs that don't fit the y / valid channels (e.g., zkf_log2's pole
/// and domain_error flags).
///
/// Register stages = STAGE_NORMALIZE+STAGE_PACK+STAGE_OUTPUT
///
/// Zero-bubble, throughput-1, no backpressure. Reset clears only the control signals.
///
/// The result exponent (unbiased/biased depending on EXP_IS_BIASED) is computed as exp = EXP_OFFSET - normshift_count;
/// EXP_OFFSET must satisfy 0 <= EXP_OFFSET < 2^WEU.
///
/// EXP_IS_BIASED: 0 = `exp` is unbiased (helper passes it to _zkf_pack so the packer adds the bias);
///                1 = `exp` is already biased (the caller folded the bias into EXP_OFFSET to skip the packer's
///                    bias add -- used by zkf_from_int with EXP_OFFSET = WX-1+BIAS).
///
/// Callers that don't need the sideband should set its width SB_W=1 and stub with a constant.

`default_nettype none

module _zkf_fixed_to_float #(
    parameter WEXP                  = 6,    // exponent field width
    parameter WMAN                  = 18,   // significand precision including the hidden bit
    parameter WMAG                  = 64,   // width of the unsigned magnitude fed to the normalizer
    parameter WEU                   = 8,    // internal signed exponent width, also passed to _zkf_pack as WEXP_UNBIASED
    parameter integer EXP_OFFSET    = 0,
    parameter integer EXP_IS_BIASED = 0,
    parameter SB_W                  = 1,    // generic sideband width carried alongside the pipeline
    parameter STAGE_NORMALIZE       = 0,    // {0,1,2} direct forward to _zkf_normshift.STAGE_SPLIT
    parameter STAGE_PACK            = 0,    // {0,1} direct forward to _zkf_pack.STAGE_INPUT
    parameter STAGE_OUTPUT          = 0     // {0,1} direct forward to _zkf_pack.STAGE_OUTPUT
) (
    input  wire clk,
    input  wire rst,

    input  wire                 in_valid,
    input  wire                 sign,
    input  wire                 force_inf,
    // mag is the wide unsigned magnitude carrier; its top bits are structural headroom that never toggle. Its
    // meaningful bits are sliced into significand/GRS and exercised end-to-end by the from_int / log2 suites.
    // verilator coverage_off
    input  wire     [WMAG-1:0]  mag,
    // verilator coverage_on
    input  wire     [SB_W-1:0]  sb_in,

    output wire                  out_valid,
    output wire [WEXP+WMAN-1:0]  y,
    output wire     [SB_W-1:0]   sb_out
);
    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wman
            _zkf_invalid_wexp_or_wman u_invalid();
        end
        if (WEU < WEXP + 2) begin : g_invalid_weu
            _zkf_invalid_fixed_to_float_weu_too_narrow u_invalid();
        end
        if ((EXP_OFFSET < 0) || (EXP_OFFSET >= (1 << WEU))) begin : g_invalid_exp_offset
            _zkf_invalid_fixed_to_float_exp_offset_out_of_range u_invalid();
        end
        if ((STAGE_NORMALIZE < 0) || (STAGE_NORMALIZE > 2)) begin : g_invalid_stage_normalize
            _zkf_invalid_stage_normalize_out_of_range u_invalid();
        end
        if ((STAGE_PACK < 0) || (STAGE_PACK > 1)) begin : g_invalid_stage_pack
            _zkf_invalid_stage_pack_out_of_range u_invalid();
        end
        if (SB_W < 1) begin : g_invalid_sb_w
            _zkf_invalid_sb_w_too_narrow u_invalid();
        end
    endgenerate
    // verilator coverage_on

    localparam WIDX = $clog2(WMAG);

    // -- Normalize the magnitude. STAGE_NORMALIZE directly forwards to _zkf_normshift.STAGE_SPLIT (0=no internal
    // register, 1=one barrier mid-cascade, 2=two barriers; see hdl/_zkf_normshift.v). norm_count is the left-shift
    // amount; norm_zero asserts when mag == 0; norm_aligned has the leading 1 at bit WMAG-1 for nonzero input.
    wire              norm_zero;
    // verilator coverage_off
    // norm_count's top bits assert only for normalize distances the small coverage formats cannot reach (the wide
    // formats in the correctness suite do); the aligned bus's bits are sliced into significand / G / R / sticky below.
    // Both stay internal intermediates -- end-to-end coverage comes from the two callers' cocotb suites.
    wire [WIDX-1:0]   norm_count;
    wire [WMAG-1:0]   norm_aligned;
    // verilator coverage_on
    _zkf_normshift #(.W(WMAG), .STAGE_SPLIT(STAGE_NORMALIZE)) u_norm (
        .clk(clk),
        .x(mag),
        .zero(norm_zero),
        .count(norm_count),
        .y(norm_aligned)
    );

    // -- Delay {sign, force_inf, sb_in} alongside the normshift so they land with norm_aligned. zkf_pipe resets only
    // the valid flag; the payload free-runs (project reset policy). For STAGE_NORMALIZE=0 the pipe is a passthrough.
    localparam PIPE_W = 2 + SB_W;
    wire              sb_valid;
    wire [PIPE_W-1:0] sb_pipe_out;
    zkf_pipe #(.W(PIPE_W), .N(STAGE_NORMALIZE)) u_sb_pipe (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in({sign, force_inf, sb_in}),
        .out_valid(sb_valid), .out(sb_pipe_out)
    );
    wire             sign_d       = sb_pipe_out[PIPE_W-1];
    wire             force_inf_d  = sb_pipe_out[PIPE_W-2];
    wire [SB_W-1:0]  sb_d         = sb_pipe_out[SB_W-1:0];

    // -- Pack-input combine (combinational). Slicing follows zkf_from_int's pattern exactly: the leading WMAN bits
    // of the aligned bus carry the significand (hidden bit included), the next bit is guard, then round, and the OR
    // of the rest is sticky.
    wire [WMAN-1:0]  pre_sig    =  norm_aligned[WMAG-1 -: WMAN];
    wire             pre_guard  =  norm_aligned[WMAG-WMAN-1];
    wire             pre_round  =  norm_aligned[WMAG-WMAN-2];
    wire             pre_sticky = |norm_aligned[WMAG-WMAN-3:0];

    // exp = EXP_OFFSET - norm_count, as a signed WEU-bit value. EXP_OFFSET is a positive integer parameter that
    // fits in WEU bits unsigned (guarded above), so the WEU-bit slice is exact and the subtraction never wraps for
    // valid norm_count. For zkf_from_int (EXP_IS_BIASED=1) this is the biased exponent EXP_BIASED_TOP - shamt and is
    // forwarded to _zkf_pack with the bias-add disabled; for zkf_log2 it is the unbiased exponent.
    // verilator coverage_off
    // The constant pad bits below the active range are structurally zero; covered downstream through y.
    localparam        [WEU-1:0] EXP_OFFSET_LOC = EXP_OFFSET[WEU-1:0];
    wire        [WEU-1:0] norm_count_ext = {{(WEU-WIDX){1'b0}}, norm_count};
    wire signed [WEU-1:0] pre_exp        = $signed(EXP_OFFSET_LOC) - $signed(norm_count_ext);
    // verilator coverage_on

    wire pre_force_inf  = force_inf_d;
    wire pre_force_zero = ~force_inf_d & norm_zero;

    // -- The packer owns its optional input register (STAGE_INPUT=STAGE_PACK) and its optional output
    // register (STAGE_OUTPUT). When STAGE_PACK=1, the rounder is insulated from the wide normshift output
    // cone at the cost of one extra cycle of latency; this is what zkf_log2 needs at WMAN=53.
    _zkf_pack #(
        .WEXP(WEXP), .WMAN(WMAN),
        .WEXP_UNBIASED(WEU),
        .EXP_IS_BIASED(EXP_IS_BIASED),
        .STAGE_INPUT(STAGE_PACK),
        .STAGE_OUTPUT(STAGE_OUTPUT)
    ) u_pack (
        .clk(clk),
        .rst(rst),
        .in_valid(sb_valid),
        .sign(sign_d),
        .force_zero(pre_force_zero),
        .force_inf(pre_force_inf),
        .exp_unbiased(pre_exp),
        .significand(pre_sig),
        .guard(pre_guard),
        .round(pre_round),
        .sticky(pre_sticky),
        .out_valid(out_valid),
        .y(y)
    );

    // -- Forward sideband through the packer's input + output stages so sb_out lands with out_valid. Pure datapath:
    // the delay free-runs with no reset; sb_out is only sampled in lockstep with out_valid, which is reset.
    _zkf_pack_delay #(.W(SB_W), .STAGE_INPUT(STAGE_PACK), .STAGE_OUTPUT(STAGE_OUTPUT)) u_sb_pack_delay (
        .clk(clk), .x(sb_d), .y(sb_out)
    );
endmodule

`default_nettype wire
