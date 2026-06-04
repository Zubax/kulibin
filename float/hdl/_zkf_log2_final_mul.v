/// Final ``l = t * P`` multiply for the log2 table+polynomial cores. The Horner output ``acc`` (signed, positive in
/// this regime: ``log2(1+t) > 0`` for ``t in (0,1)``) is multiplied by the stored fraction ``frac`` (unsigned), and the
/// product is truncated to F2 = WFRAC + CF fractional bits.
///
/// Zero-bubble; the sideband and valid pipe along the same register stages as the data.
///
/// The operands are always latched in a shared input register first, so the multiply has registers on BOTH sides. This
/// keeps the long route from the upstream Horner accumulator off the multiply's combinational cone. Total register
/// stages are 2+STAGE_PRODUCT:
///   STAGE_PRODUCT = 0: single multiply -> 2 register stages.
///   STAGE_PRODUCT = 1: 2x2 split -> 3 register stages.
///   STAGE_PRODUCT = 2: 2x2 split with an extra operand-capture stage -> 4 register stages.
///   STAGE_PRODUCT = 3: 3x3 split with an extra operand-capture stage -> 5 register stages.

`default_nettype none

module _zkf_log2_final_mul #(
    parameter integer WFRAC         = 17,
    parameter integer WACC          = 35,
    parameter integer F2            = 47,    // = WFRAC + CF
    parameter integer WSB           = 1,
    parameter integer STAGE_PRODUCT = 0      // product computation staging; see _zkf_horner
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    in_valid,
    input  wire        [WSB-1:0]   sb_in,
    input  wire        [WFRAC-1:0] frac,
    // acc carries the Horner result P(t) = log2(1+t)/t in [1, 1/ln2] at scale 2**CF; its bits above CF are structural
    // headroom that never toggle. Its meaningful bits are exercised end-to-end by the log2 suite (i_acc below mirrors
    // it one register stage later).
    // verilator coverage_off
    input  wire signed [WACC-1:0]  acc,     // > 0 in this regime
    // verilator coverage_on
    output wire                    out_valid,
    output wire        [WSB-1:0]   sb_out,
    output wire        [F2-1:0]    l_fix
);
    // verilator coverage_off
    generate
        if ((STAGE_PRODUCT < 0) || (STAGE_PRODUCT > 3)) begin : g_invalid_stage_product
            _zkf_invalid_stage_product_out_of_range u_invalid();
        end
    endgenerate
    // verilator coverage_on

    // Operand chunk widths (acc treated as unsigned, since acc > 0 in the log2 t*P regime).
    localparam integer WFA_LO = (WFRAC + 1) / 2;
    localparam integer WFA_HI = WFRAC - WFA_LO;
    localparam integer WAC_LO = (WACC + 1) / 2;
    localparam integer WAC_HI = WACC - WAC_LO;
    localparam integer WFA0 = (WFRAC + 2) / 3;
    localparam integer WFA1 = (WFRAC + 1) / 3;
    localparam integer WFA2 = (WFRAC - WFA0 - WFA1 > 0) ? (WFRAC - WFA0 - WFA1) : 1;
    localparam integer WAC0 = (WACC + 2) / 3;
    localparam integer WAC1 = (WACC + 1) / 3;
    localparam integer WAC2 = (WACC - WAC0 - WAC1 > 0) ? (WACC - WAC0 - WAC1) : 1;

    // -- Input register stage: latch the operands at the module boundary so the multiply has registers on BOTH sides
    // (this register maps to the DSP's input register; the partial-product registers below are the output side). The
    // Horner accumulator otherwise drives the multiply across a long unregistered route -- the placement-critical
    // path at wide WMAN, where route + multiply + route land in one period. Adds one register stage. Datapath
    // operands free-run (only valid is reset), per the project reset policy.
    reg  [WFRAC-1:0]       i_frac;
    // verilator coverage_off
    reg  signed [WACC-1:0] i_acc;   // mirrors the acc port (structural top bits); see the acc port comment above
    // verilator coverage_on
    reg                    i_v;
    reg  [WSB-1:0]         i_sb;
    always @(posedge clk) begin
        if (rst) i_v <= 1'b0;
        else     i_v <= in_valid;
        i_frac <= frac;
        i_acc  <= acc;
        i_sb   <= sb_in;
    end

    wire [WFRAC-1:0]        p_frac;
    // verilator coverage_off
    wire signed [WACC-1:0]  p_acc;
    // verilator coverage_on
    wire                    p_v;
    wire [WSB-1:0]          p_sb;

    generate
        if ((STAGE_PRODUCT == 2) || (STAGE_PRODUCT == 3)) begin : g_product_input_stage
            reg [WFRAC-1:0]        x_frac;
            // verilator coverage_off
            reg signed [WACC-1:0]  x_acc;
            // verilator coverage_on
            reg                    x_v;
            reg [WSB-1:0]          x_sb;
            always @(posedge clk) begin
                if (rst) x_v <= 1'b0;
                else     x_v <= i_v;
                x_frac <= i_frac;
                x_acc  <= i_acc;
                x_sb   <= i_sb;
            end
            assign p_frac = x_frac;
            assign p_acc  = x_acc;
            assign p_v    = x_v;
            assign p_sb   = x_sb;
        end else begin : g_product_input_direct
            assign p_frac = i_frac;
            assign p_acc  = i_acc;
            assign p_v    = i_v;
            assign p_sb   = i_sb;
        end
    endgenerate

    generate
        if (STAGE_PRODUCT == 0) begin : g_single
            // -- 1 multiply stage (after the shared input register): single combinational multiply, truncate, register.
            // verilator coverage_off
            wire [WFRAC+WACC-1:0] prod = p_frac * p_acc;
            // verilator coverage_on
            reg [F2-1:0]  r_l;
            reg           r_v;
            reg [WSB-1:0] r_sb;
            always @(posedge clk) begin
                if (rst) r_v <= 1'b0;
                else     r_v <= p_v;
                r_l  <= prod[F2-1:0];
                r_sb <= p_sb;
            end
            assign l_fix     = r_l;
            assign out_valid = r_v;
            assign sb_out    = r_sb;
        end else if ((STAGE_PRODUCT == 1) || (STAGE_PRODUCT == 2)) begin : g_split2
            // -- 2 register stages: 4 half-width sub-products | sum + truncate. --
            // verilator coverage_off
            wire [WFA_LO-1:0]            fa_lo = p_frac[WFA_LO-1:0];
            wire [WFA_HI-1:0]            fa_hi = p_frac[WFRAC-1:WFA_LO];
            wire [WAC_LO-1:0]            ac_lo = p_acc[WAC_LO-1:0];
            wire [WAC_HI-1:0]            ac_hi = p_acc[WACC-1:WAC_LO];
            wire [WFA_LO+WAC_LO-1:0]     q_ll  = fa_lo * ac_lo;
            wire [WFA_LO+WAC_HI-1:0]     q_lh  = fa_lo * ac_hi;
            wire [WFA_HI+WAC_LO-1:0]     q_hl  = fa_hi * ac_lo;
            wire [WFA_HI+WAC_HI-1:0]     q_hh  = fa_hi * ac_hi;
            reg  [WFA_LO+WAC_LO-1:0]     m_q_ll;
            reg  [WFA_LO+WAC_HI-1:0]     m_q_lh;
            reg  [WFA_HI+WAC_LO-1:0]     m_q_hl;
            reg  [WFA_HI+WAC_HI-1:0]     m_q_hh;
            // verilator coverage_on
            reg                          m_v;
            reg  [WSB-1:0]               m_sb;
            always @(posedge clk) begin
                if (rst) m_v <= 1'b0;
                else     m_v <= p_v;
                m_q_ll <= q_ll;
                m_q_lh <= q_lh;
                m_q_hl <= q_hl;
                m_q_hh <= q_hh;
                m_sb   <= p_sb;
            end
            // verilator coverage_off
            wire [WFRAC+WACC-1:0] sum2 = ({{(WFRAC+WACC-WFA_HI-WAC_HI){1'b0}}, m_q_hh} << (WFA_LO + WAC_LO))
                                       + ({{(WFRAC+WACC-WFA_HI-WAC_LO){1'b0}}, m_q_hl} << WFA_LO)
                                       + ({{(WFRAC+WACC-WFA_LO-WAC_HI){1'b0}}, m_q_lh} << WAC_LO)
                                       +  {{(WFRAC+WACC-WFA_LO-WAC_LO){1'b0}}, m_q_ll};
            // verilator coverage_on
            reg [F2-1:0]  r_l;
            reg           r_v;
            reg [WSB-1:0] r_sb;
            always @(posedge clk) begin
                if (rst) r_v <= 1'b0;
                else     r_v <= m_v;
                r_l  <= sum2[F2-1:0];
                r_sb <= m_sb;
            end
            assign l_fix     = r_l;
            assign out_valid = r_v;
            assign sb_out    = r_sb;
        end else if (STAGE_PRODUCT == 3) begin : g_split3
            // -- 3 register stages: 9 third-width sub-products | per-acc-chunk row sums (3) | combine + truncate. --
            // verilator coverage_off
            wire [WFA0-1:0] fa0 = p_frac[WFA0-1:0];
            wire [WFA1-1:0] fa1 = p_frac[WFA0+WFA1-1:WFA0];
            wire [WFA2-1:0] fa2 = p_frac[WFRAC-1:WFA0+WFA1];
            wire [WAC0-1:0] ac0 = p_acc[WAC0-1:0];
            wire [WAC1-1:0] ac1 = p_acc[WAC0+WAC1-1:WAC0];
            wire [WAC2-1:0] ac2 = p_acc[WACC-1:WAC0+WAC1];
            wire [WFA0+WAC0-1:0] q00 = fa0 * ac0;
            wire [WFA0+WAC1-1:0] q01 = fa0 * ac1;
            wire [WFA0+WAC2-1:0] q02 = fa0 * ac2;
            wire [WFA1+WAC0-1:0] q10 = fa1 * ac0;
            wire [WFA1+WAC1-1:0] q11 = fa1 * ac1;
            wire [WFA1+WAC2-1:0] q12 = fa1 * ac2;
            wire [WFA2+WAC0-1:0] q20 = fa2 * ac0;
            wire [WFA2+WAC1-1:0] q21 = fa2 * ac1;
            wire [WFA2+WAC2-1:0] q22 = fa2 * ac2;
            // -- Stage 1: register the 9 sub-products. --
            reg  [WFA0+WAC0-1:0] m_q00;
            reg  [WFA0+WAC1-1:0] m_q01;
            reg  [WFA0+WAC2-1:0] m_q02;
            reg  [WFA1+WAC0-1:0] m_q10;
            reg  [WFA1+WAC1-1:0] m_q11;
            reg  [WFA1+WAC2-1:0] m_q12;
            reg  [WFA2+WAC0-1:0] m_q20;
            reg  [WFA2+WAC1-1:0] m_q21;
            reg  [WFA2+WAC2-1:0] m_q22;
            // verilator coverage_on
            reg                  m_v;
            reg  [WSB-1:0]       m_sb;
            always @(posedge clk) begin
                if (rst) m_v <= 1'b0;
                else     m_v <= p_v;
                m_q00 <= q00; m_q01 <= q01; m_q02 <= q02;
                m_q10 <= q10; m_q11 <= q11; m_q12 <= q12;
                m_q20 <= q20; m_q21 <= q21; m_q22 <= q22;
                m_sb  <= p_sb;
            end
            // -- Stage 2: row sums (each sums 3 sub-products with frac-chunk shifts <= WFRAC). --
            // verilator coverage_off
            wire [WFRAC+WACC-1:0] row0 = ({{(WFRAC+WACC-WFA2-WAC0){1'b0}}, m_q20} << (WFA0 + WFA1))
                                       + ({{(WFRAC+WACC-WFA1-WAC0){1'b0}}, m_q10} << WFA0)
                                       +  {{(WFRAC+WACC-WFA0-WAC0){1'b0}}, m_q00};
            wire [WFRAC+WACC-1:0] row1 = ({{(WFRAC+WACC-WFA2-WAC1){1'b0}}, m_q21} << (WFA0 + WFA1))
                                       + ({{(WFRAC+WACC-WFA1-WAC1){1'b0}}, m_q11} << WFA0)
                                       +  {{(WFRAC+WACC-WFA0-WAC1){1'b0}}, m_q01};
            wire [WFRAC+WACC-1:0] row2 = ({{(WFRAC+WACC-WFA2-WAC2){1'b0}}, m_q22} << (WFA0 + WFA1))
                                       + ({{(WFRAC+WACC-WFA1-WAC2){1'b0}}, m_q12} << WFA0)
                                       +  {{(WFRAC+WACC-WFA0-WAC2){1'b0}}, m_q02};
            reg [WFRAC+WACC-1:0] s_row0, s_row1, s_row2;
            // verilator coverage_on
            reg                  s_v;
            reg  [WSB-1:0]       s_sb;
            always @(posedge clk) begin
                if (rst) s_v <= 1'b0;
                else     s_v <= m_v;
                s_row0 <= row0;
                s_row1 <= row1;
                s_row2 <= row2;
                s_sb   <= m_sb;
            end
            // -- Stage 3: combine the 3 row sums (acc-chunk shifts) and truncate to F2. --
            // verilator coverage_off
            wire [WFRAC+WACC-1:0] sum3 = (s_row2 << (WAC0 + WAC1)) + (s_row1 << WAC0) + s_row0;
            // verilator coverage_on
            reg [F2-1:0]  r_l;
            reg           r_v;
            reg [WSB-1:0] r_sb;
            always @(posedge clk) begin
                if (rst) r_v <= 1'b0;
                else     r_v <= s_v;
                r_l  <= sum3[F2-1:0];
                r_sb <= s_sb;
            end
            assign l_fix     = r_l;
            assign out_valid = r_v;
            assign sb_out    = r_sb;
        end else begin : g_invalid
            assign l_fix     = {F2{1'b0}};
            assign out_valid = 1'b0;
            assign sb_out    = {WSB{1'b0}};
        end
    endgenerate
endmodule

`default_nettype wire
