/// Elaboration-time constant generator. The packed output encodes VALUE in the ZKF format; all math runs during
/// elaboration so synthesis sees a constant net.
///
/// VALUE is an IEEE 754 binary64 literal (Verilog `real`). Special cases:
///   - +0.0 and -0.0 produce canonical +0.
///   - NaN triggers an elaboration error.
///   - |VALUE| above the format max or below the smallest normal triggers an elaboration error.
///
/// Infinity is requested via the INF parameter, not via VALUE: INF > 0 emits +inf, INF < 0 emits -inf, and the
/// default INF = 0 selects the VALUE path. The reason for the separate parameter is a Verilator constant-folding bug
/// that turns +inf into 0 when it crosses a `parameter real` boundary, so passing 1.0/0.0 as VALUE would silently
/// encode +0 under Verilator, and possibly some other tools. The integer INF parameter is unaffected.
///
/// Precision: `real` carries at most 53 significand bits, so WMAN > 53 is rejected at elaboration. For WMAN <= 53
/// the encoded value is bit-exact under round-to-nearest, ties-to-even.
///
/// Implementation note: the bit pattern is built from real arithmetic rather than $realtobits because some tools refuse
/// to fold $realtobits in constant context. The math helpers below are hand-rolled to work around several gaps in
/// what Verilog gives us at elaboration time; see the block before f_pow2 for the details.

`default_nettype none

module zkf_const #(
    parameter         WEXP  = 6,    // exponent bit width
    parameter         WMAN  = 18,   // significand bit width
    parameter real    VALUE = 0.0,  // value to encode
    parameter integer INF   = 0     // if nonzero, y is an infinity with the same sign; VALUE is ignored
) (
    output wire [WEXP+WMAN-1:0] y   // constructed constant value derived from VALUE
);
    // verilator coverage_off
    generate
        if ((WEXP < 2) || (WMAN < 4)) begin : g_invalid_wm
            _zkf_invalid_wexp_or_wman u_invalid();
        end
        if (WMAN > 53) begin : g_invalid_wide
            _zkf_invalid_const_wman_exceeds_real_precision u_invalid();
        end
    endgenerate
    // verilator coverage_on

    localparam            WFRAC   = WMAN - 1;
    localparam            WFULL   = WEXP + WMAN;
    localparam [WEXP-1:0] EXP_INF = {WEXP{1'b1}};
    localparam integer    BIAS    = (1 << (WEXP - 1)) - 1;
    localparam integer    EMAX    = BIAS;       // max unbiased exponent
    localparam integer    EMIN    = 1 - BIAS;   // min unbiased exponent

    // Function result carries a status code so elaboration-time generate guards can turn out-of-range VALUE into
    // a build error rather than silently encoding.
    localparam [2:0] STATUS_OK            = 3'd0;
    localparam [2:0] STATUS_NAN           = 3'd1;
    localparam [2:0] STATUS_OVERFLOW      = 3'd2;
    localparam [2:0] STATUS_UNDERFLOW     = 3'd3;
    localparam [2:0] STATUS_INF_VIA_VALUE = 3'd4;
    localparam       STATUS_W             = 3;
    localparam       RESULT_W             = WFULL + STATUS_W;

    // Why these helpers are hand-rolled rather than calls into the system library:
    //
    //   * No exact power-of-two for a real result. `**` and `$pow` are not reliably constant-evaluable across
    //     simulators, and even when they are they produce FP-rounded results. f_pow2 uses repeated multiplication
    //     by 2.0, which only adjusts the IEEE 754 exponent field and is therefore bit-exact for any integer power
    //     in the double-precision range.
    //   * No $log2. $ln exists but is FP-approximate, so $floor($ln(x)/$ln(2.0)) can be off by one at the exact
    //     powers of two. f_floor_log2 starts from that approximation and corrects via comparisons against pow2(e±1).
    //   * No round-to-nearest-ties-to-even primitive. $rtoi truncates toward zero, and $floor(x+0.5) rounds halves
    //     away from zero. f_round_rte implements RTNE explicitly to match the rest of the float library.
    //   * No real → wide-integer conversion. $rtoi returns the 32-bit `integer` type, which is too narrow for the
    //     rounded significand when WMAN approaches 53. $realtobits would expose all 53 bits at once but Icarus
    //     refuses to fold it in constant context, so f_real_to_uint peels bits off the top via pow2(i) compares.

    // Function bodies execute only at elaboration time; the simulator never reaches them at runtime,
    // so Verilator would otherwise count every function line as uncovered. Mark the entire block off
    // for line/toggle coverage. Correctness is checked via the test_const.py vectors that compare the
    // packed output against IEEE references.
    // verilator coverage_off

    // Exact integer power of two as a real.
    function automatic real f_pow2;
        input integer e;
        real    r;
        integer i;
        begin
            r = 1.0;
            if (e >= 0) begin
                for (i = 0; i < e; i = i + 1) r = r * 2.0;
            end else begin
                for (i = 0; i < -e; i = i + 1) r = r / 2.0;
            end
            f_pow2 = r;
        end
    endfunction

    // floor(log2(x)) for x > 0, exact.
    function automatic integer f_floor_log2;
        input real x;
        integer e;
        begin
            e = $rtoi($floor($ln(x) / $ln(2.0)));
            if (f_pow2(e + 1) <= x) e = e + 1;
            if (f_pow2(e)     >  x) e = e - 1;
            f_floor_log2 = e;
        end
    endfunction

    // Round real to nearest integer, ties to even. Returns a real so the result can hold all 53 bits.
    function automatic real f_round_rte;
        input real x;
        real fl;
        real diff;
        real half;
        begin
            fl   = $floor(x);
            diff = x - fl;
            if (diff < 0.5) begin
                f_round_rte = fl;
            end else if (diff > 0.5) begin
                f_round_rte = fl + 1.0;
            end else begin
                // Exact tie: round to even. fl is even iff fl/2 is an integer.
                half = fl / 2.0;
                if (half == $floor(half)) f_round_rte = fl;
                else                      f_round_rte = fl + 1.0;
            end
        end
    endfunction

    // Convert a non-negative real that fits in WMAN+1 bits to an unsigned integer of the same width.
    function automatic [WMAN:0] f_real_to_uint;
        input real x;
        real r;
        integer i;
        reg [WMAN:0] acc;
        begin
            r   = x;
            acc = {(WMAN+1){1'b0}};
            for (i = WMAN; i >= 0; i = i - 1) begin
                if (f_pow2(i) <= r) begin
                    acc[i] = 1'b1;
                    r      = r - f_pow2(i);
                end
            end
            f_real_to_uint = acc;
        end
    endfunction

    function automatic [RESULT_W-1:0] f_classify_pack;
        input real v;
        real               absv;
        real               scaled;
        real               m_real;
        real               sig_real;
        integer            eu;
        integer            eu_final;
        integer            exp_biased;
        reg [WMAN:0]       sig_int;
        reg                sign;
        reg [WEXP-1:0]     exp_field;
        reg [WFRAC-1:0]    frac_field;
        reg [WFULL-1:0]    packed_bits;
        reg [STATUS_W-1:0] status;
        begin
            packed_bits = {WFULL{1'b0}};
            status      = STATUS_OK;
            sign        = (v < 0.0);

            if (v != v) begin
                // NaN is the only value that fails self-equality.
                status = STATUS_NAN;
            end else if (v == 0.0) begin
                // +0.0 and -0.0 both compare equal to 0; both collapse to canonical +0.
            end else if (v == (v * 2.0)) begin
                // Among non-zero values only ±inf satisfies v == 2v. Route inf through the INF parameter rather
                // than VALUE because Verilator's constant-folder silently drops +inf at parameter binding.
                status = STATUS_INF_VIA_VALUE;
            end else begin
                absv     = sign ? -v : v;
                eu       = f_floor_log2(absv);
                scaled   = absv / f_pow2(eu);              // in [1.0, 2.0)
                m_real   = scaled * f_pow2(WFRAC);          // in [2^WFRAC, 2^WMAN)
                sig_real = f_round_rte(m_real);
                sig_int  = f_real_to_uint(sig_real);

                // Renormalization: rounding may have pushed the significand to exactly 2.0, i.e. sig_int = 2^WMAN
                // (bit WMAN set). Bumping the exponent restores the [1.0, 2.0) range; stored fraction is all-zero.
                if (sig_int[WMAN]) begin
                    eu_final   = eu + 1;
                    frac_field = {WFRAC{1'b0}};
                end else begin
                    eu_final   = eu;
                    frac_field = sig_int[WFRAC-1:0];
                end

                if (eu_final > EMAX) begin
                    status = STATUS_OVERFLOW;
                end else if (eu_final < EMIN) begin
                    status = STATUS_UNDERFLOW;
                end else begin
                    exp_biased  = eu_final + BIAS;
                    exp_field   = exp_biased[WEXP-1:0];
                    packed_bits = {sign, exp_field, frac_field};
                end
            end

            f_classify_pack = {status, packed_bits};
        end
    endfunction
    // verilator coverage_on

    // Result of evaluating VALUE; ignored when INF != 0.
    localparam [RESULT_W-1:0] R_VAL      = f_classify_pack(VALUE);
    localparam [STATUS_W-1:0] STATUS_VAL = R_VAL[RESULT_W-1:WFULL];
    localparam [WFULL-1:0]    PACKED_VAL = R_VAL[WFULL-1:0];

    // INF-mode packed bits; sign follows the sign of the INF parameter.
    localparam                INF_MODE   = (INF != 0);
    localparam [WFULL-1:0]    PACKED_INF = {(INF < 0), EXP_INF, {WFRAC{1'b0}}};

    localparam [STATUS_W-1:0] STATUS = INF_MODE ? STATUS_OK : STATUS_VAL;
    localparam [WFULL-1:0]    PACKED = INF_MODE ? PACKED_INF : PACKED_VAL;

    // verilator coverage_off
    generate
        if (STATUS == STATUS_NAN) begin : g_invalid_nan
            _zkf_invalid_const_nan_value u_invalid();
        end
        if (STATUS == STATUS_OVERFLOW) begin : g_invalid_overflow
            _zkf_invalid_const_overflows_format u_invalid();
        end
        if (STATUS == STATUS_UNDERFLOW) begin : g_invalid_underflow
            _zkf_invalid_const_underflows_format u_invalid();
        end
        if (STATUS == STATUS_INF_VIA_VALUE) begin : g_invalid_inf_via_value
            _zkf_invalid_const_inf_must_be_set_via_inf_parameter u_invalid();
        end
    endgenerate
    // verilator coverage_on

    assign y = PACKED;
endmodule

`default_nettype wire
