// Write-only driver for the MAX5725 octal 12-bit voltage-output SPI DAC, and for the MAX5723 (8-bit) and
// MAX5724 (10-bit), whose codes share the same left-justified field. All outputs updated synchronously.
//
// Three pins are driven: io_cs_n (CSB), io_sclk (SCLK), io_mosi (DIN). DOUT and IRQ are unused, so nothing is
// read back and there is no chain mode, hence N <= 8. The DAC must strap LDAC and CLR inactive and tie M/Z
// to VDD or GND -- M/Z is referenced to VDD, not VDDIO, so a VDDIO strap is only valid when the rails match.
// The configuration sets CLEAR_ENB so a low CLR cannot clear the outputs, but a low LDAC makes the DAC
// latches transparent and destroys the simultaneous update.
//
// in_words is N words aligned to the top of the 12-bit code field, W sets the resolution.
// in_signed is per channel and latched with the sample; a set bit reads that word as two's complement.
//
// An update writes every channel's CODE register and then LOAD_ALL, which is what steps the outputs together.
// CODEn_LOAD_ALL would save a frame but skips channels whose CODE has not changed.
//
// Configuration runs after reset and on each rising edge of cfg_apply, which exists for a DAC powered after
// the FPGA, whose calibration would otherwise swallow the automatic sequence; both paths wait out
// STARTUP_CYCLES first. Tying cfg_apply low is the right default. cfg_ref is captured when the edge arrives
// rather than when it is served, and edges arriving while a request is outstanding fold into it. The sequence
// opens with SW_RESET, which drives the outputs to the device's M/Z default -- zero scale when M/Z is low, mid
// scale when high -- so follow a reconfiguration with an update if the outputs matter. A cfg_apply raised on
// the same cycle as an accepted sample does not outrank it, so raise it when idle.
//
// io_sclk is clk/SCLK_DIV and toggles only inside a frame, keeping digital noise off the outputs between
// updates. io_mosi changes on the rising edge and the device samples it on the falling edge, so setup and
// hold get half a period each -- the split that maximises the smaller of the two. io_cs_n falls, and the
// first bit is presented, a full period ahead of that first falling edge: that is tCSS0's margin, and it
// spares the first bit having to swing from its parked level in half a period.

`default_nettype none

module max5725#(
    parameter W        = 12,            // Word width; aligned to the top of the code field, zero-filled or truncated
    parameter N        = 8,             // Number of DAC channels in use, 1 .. 8
    parameter CLK_HZ   = 100_000_000,   // Real frequency of clk; the absolute-time IO limits derive from it
    parameter SCLK_DIV = 2,             // clk-to-io_sclk division factor; shall be even and at least 2
    // Hold-off covering the device's power-up calibration, which the data sheet gives as 200 us TYPICAL with
    // no maximum. This default is 400 us -- twice typical, not a guaranteed bound.
    parameter STARTUP_CYCLES = (CLK_HZ + 2499) / 2500
)(
    input wire clk,
    input wire rst,

    input wire [1:0] cfg_ref,           // 00=ext, 01=2.500V, 10=2.048V, 11=4.096V
    input wire cfg_apply,               // One cycle is enough

    input  wire in_valid,               // Ignored while in_ready is low
    output wire in_ready,
    input  wire [(W*N)-1:0] in_words,   // Word 0 is OUT0
    input  wire [N-1:0] in_signed,

    // Initialised so CSB idles high from the end of bitstream configuration, not from the first clk edge.
    // This is not essential though.
    output reg io_sclk = 1'b0,  // SCLK
    output reg io_cs_n = 1'b1,  // CSB, active low
    output reg io_mosi = 1'b0   // DIN
);
    // How much of each input word reaches the code field, and the power of two that lifts it into place.
    localparam TAKE = (W < 12) ? W : 12;
    localparam [11:0] FILL_SCALE = 12'd1 << (12 - TAKE);

    localparam FRAME_BITS = 24;                     // Every SPI operation is one 24-bit word
    localparam HALF       = SCLK_DIV / 2;

    // Whole clk cycles spanning each interval the data sheet states in absolute time, rounded up.
    localparam CYC_8NS   = (CLK_HZ + 124_999_999) / 125_000_000;
    localparam CYC_20NS  = (CLK_HZ +  49_999_999) /  50_000_000;
    localparam CYC_100NS = (CLK_HZ +   9_999_999) /  10_000_000;

    // Cycles io_cs_n stays deasserted between frames. The realised tCSF is HALF + GAP_CYCLES + 1 cycles, since it runs
    // from the last falling edge and io_cs_n falls a cycle after the counter expires; tCSPW gets GAP_CYCLES + 1.
    localparam GAP_CYCLES = CYC_100NS + 2;

    localparam CODE_BURSTS = N;
    localparam UPD_BURSTS  = CODE_BURSTS + 1;
    localparam INIT_BURSTS = 4;                     // SW_RESET, POWER, CONFIG, REF

    localparam PH_W   = $clog2(SCLK_DIV);           // SCLK_DIV >= 2 makes this at least 1
    localparam BIT_W  = $clog2(FRAME_BITS + 1);
    localparam GAP_MAX = (STARTUP_CYCLES > GAP_CYCLES) ? STARTUP_CYCLES : GAP_CYCLES;
    localparam GAP_W  = $clog2(GAP_MAX + 1);
    localparam BST_MAX  = (INIT_BURSTS > UPD_BURSTS) ? INIT_BURSTS : UPD_BURSTS;
    localparam BST_FIT  = $clog2(BST_MAX + 1);
    // Never narrower than three bits: the burst index doubles as the CODEn channel field, and a two-bit
    // counter would make that part-select reach past the end of the vector.
    localparam BST_W    = (BST_FIT < 3) ? 3 : BST_FIT;

    // Sized forms of the above so that the comparisons in the engine need no width casts. The implicit
    // narrowing of these 32-bit constant expressions is exactly what is intended, hence the pragma.
    /* verilator lint_off WIDTHTRUNC */
    localparam [PH_W-1:0]  PH_LAST    = SCLK_DIV - 1;
    localparam [PH_W-1:0]  PH_HALF    = HALF;
    localparam [BIT_W-1:0] BIT_LAST   = FRAME_BITS;
    localparam [GAP_W-1:0] GAP_INIT   = GAP_CYCLES;
    // The hold-off doubles as the gap before the first frame, so it can never be shorter than the inter-frame
    // gap or a small STARTUP_CYCLES would put CSB back down inside tCSF.
    localparam [GAP_W-1:0] START_INIT = (STARTUP_CYCLES > GAP_CYCLES) ? STARTUP_CYCLES : GAP_CYCLES;
    localparam [BST_W-1:0] BST_INIT   = INIT_BURSTS;
    localparam [BST_W-1:0] BST_UPD    = UPD_BURSTS;
    /* verilator lint_on WIDTHTRUNC */

    generate
        if (W < 1)                                   begin : g_chk_w      max5725_error_W_lt_1 e();   end
        if (CLK_HZ < 1)                              begin : g_chk_hz     max5725_error_CLK_HZ_lt_1 e(); end
        if (CLK_HZ > 2_000_000_000)                  begin : g_chk_hzmax  max5725_error_CLK_HZ_over_2GHz e(); end
        if (N < 1)                                   begin : g_chk_n      max5725_error_N_lt_1 e();   end
        if (N > 8)                                   begin : g_chk_nmax   max5725_error_N_over_8 e(); end
        // An odd divisor would trade tCH against tCL and shrink one of the setup/hold margins for no benefit.
        if ((SCLK_DIV < 2) || ((SCLK_DIV % 2) != 0)) begin : g_chk_div    max5725_error_SCLK_DIV_odd e(); end
        if (SCLK_DIV < CYC_20NS)                     begin : g_chk_fmax   max5725_error_SCLK_over_50MHz e(); end
        if (HALF < CYC_8NS)                          begin : g_chk_half   max5725_error_SCLK_half_under_8ns e(); end
        if (STARTUP_CYCLES < 1)                      begin : g_chk_start  max5725_error_STARTUP_lt_1 e(); end
    endgenerate

    // ------------------------------------------------ Frames ------------------------------------------------

    // Commands are B[23:16]; see Table 2 of the data sheet. DAC codes are left justified into B[15:4].
    // The 0x9630 tail of SW_RESET is the fixed key the software commands in the 0x3n group require.
    localparam [23:0] FRM_SW_RESET = 24'h35_9630;   // All CODE, DAC and control registers to their defaults
    localparam [23:0] FRM_POWER    = 24'h40_FF00;   // All eight DACs selected in B[15:8], PD[1:0]=00 Normal
    // All DACs; WC[1:0]=00 watchdog disabled, GTB=1 software gating disabled, LDB=0 DAC latch operational,
    // CLB=1 so the CLR pin and SW_CLEAR cannot disturb a device whose CLR is only weakly pulled up.
    localparam [23:0] FRM_CONFIG   = 24'h50_FF28;
    localparam [23:0] FRM_LOAD_ALL = 24'hC1_0000;   // Update every DAC register from its CODE register
    localparam [23:0] FRM_NO_OP    = 24'hC8_0000;   // B[23:16]=1100_1xxx has no effect on the device

    reg [1:0]  cfg_ref_r;
    reg [11:0] code_r [0:N-1];

    // Blocking assignments to function locals are the normal Verilog idiom; see fir.v for the same pragma.
    // verilator lint_off BLKSEQ

    // Only as many low bits of the index as N needs take part, which is what the pragma acknowledges.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [11:0] code_of;
        input integer idx;
        begin
            // Multiplying by a constant power of two is the zero-fill, and costs nothing but wiring. Two's
            // complement to the device's straight binary is an inversion of the top bit.
            code_of = (in_words[(W*idx) + (W-1) -: TAKE] * FILL_SCALE) ^ (in_signed[idx] ? 12'h800 : 12'h000);
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // The 24-bit frame belonging to the given burst of the given sequence.
    function automatic [23:0] frame_of;
        input             is_init;
        input [BST_W-1:0] burst;
        integer burst_i;
        begin
            // Widen to integer so that the array index below cannot overflow a narrow counter.
            /* verilator lint_off WIDTHEXPAND */
            burst_i = burst;
            /* verilator lint_on WIDTHEXPAND */
            if (is_init) begin
                case (burst)
                    0:       frame_of = FRM_SW_RESET;
                    1:       frame_of = FRM_POWER;
                    2:       frame_of = FRM_CONFIG;
                    // REF: B[23:20]=0010 command, B19=0, B18=1 keeps the reference powered even in standby,
                    // B[17:16] selects external or one of the three internal reference voltages.
                    3:       frame_of = {6'b001001, cfg_ref_r, 16'h0000};
                    default: frame_of = FRM_NO_OP;
                endcase
            end else if (burst_i >= CODE_BURSTS) begin
                frame_of = FRM_LOAD_ALL;
            end else begin
                // CODEn: B[23:20]=1000 command, B19=0 (a 1 would mean all DACs), B[18:16] the channel.
                frame_of = {5'b10000, burst[2:0], code_r[burst_i], 4'h0};
            end
        end
    endfunction

    // verilator lint_on BLKSEQ

    // ------------------------------------------------ Engine ------------------------------------------------

    localparam ST_IDLE  = 2'd0;     // io_cs_n deasserted, io_sclk parked, waiting for in_valid
    localparam ST_GAP   = 2'd1;     // io_cs_n deasserted, io_sclk parked, waiting out GAP_CYCLES before a frame
    localparam ST_BURST = 2'd2;     // io_cs_n asserted, shifting FRAME_BITS bits out

    reg [1:0]       state;
    reg             is_init;        // The sequence being transmitted is the configuration
    reg             init_done;
    reg [BST_W-1:0] burst_idx;
    reg [PH_W-1:0]  ph;
    reg [BIT_W-1:0] bit_cnt;        // Bits launched so far within the current frame
    reg [GAP_W-1:0] gap_cnt;
    reg [23:0]      shreg;
    reg             cfg_apply_r;    // Previous cfg_apply, so a held-high input cannot loop the sequence
    reg             cfg_pending;
    reg [1:0]       cfg_ref_pend;   // cfg_ref as it stood when the request was made, not when it is served

    wire [BST_W-1:0] num_bursts = is_init ? BST_INIT : BST_UPD;
    wire [PH_W-1:0]  ph_next    = (ph == PH_LAST) ? {PH_W{1'b0}} : (ph + 1'b1);
    wire             shifting   = bit_cnt < BIT_LAST;
    wire             launch     = (ph_next == PH_HALF) && shifting;
    wire             burst_end  = (ph_next == PH_HALF) && !shifting;
    wire             cfg_rise   = cfg_apply && !cfg_apply_r;
    wire [23:0]      next_frame = frame_of(is_init, burst_idx);

    // init_done is redundant today -- reset enters ST_GAP, so ST_IDLE is first reached at the end of a
    // sequence -- but gating on it makes this correct by construction rather than by a non-local argument
    // about reachability. Readiness is withdrawn while a request is outstanding because that request runs
    // first, and the handshake forbids dropping a sample offered while in_ready was high.
    assign in_ready = init_done && (state == ST_IDLE) && !cfg_pending;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_GAP;
            is_init      <= 1'b1;
            init_done    <= 1'b0;
            burst_idx    <= {BST_W{1'b0}};
            ph           <= {PH_W{1'b0}};
            bit_cnt      <= {BIT_W{1'b0}};
            gap_cnt      <= START_INIT;     // The device ignores commands while it calibrates after power-up
            shreg        <= 24'h000000;
            cfg_ref_r    <= cfg_ref;
            cfg_apply_r  <= cfg_apply;
            cfg_pending  <= 1'b0;
            cfg_ref_pend <= cfg_ref;
            io_sclk      <= 1'b0;
            io_cs_n      <= 1'b1;
            io_mosi      <= 1'b0;
            for (i = 0; i < N; i = i + 1) code_r[i] <= 12'h000;
        end else begin
            // Sampled up to the point where the configuration completes, so a caller may present cfg_ref
            // either during reset or while the power-up hold-off runs. Frozen from then on, until cfg_apply.
            if (!init_done) cfg_ref_r <= cfg_ref;

            cfg_apply_r <= cfg_apply;
            if (cfg_rise) begin
                cfg_pending  <= 1'b1;
                // The reference has to be captured now: a request raised during a frame is not served until
                // the engine next idles, and the caller is free to change cfg_ref in the meantime.
                cfg_ref_pend <= cfg_ref;
            end

            case (state)
                ST_IDLE: begin
                    // A pending configuration request comes first, since the codes that follow are only
                    // meaningful once the device's registers have been re-established. in_ready is withdrawn
                    // while the request is outstanding, so no sample can be dropped by this precedence.
                    if (cfg_pending) begin
                        // A fresh edge landing on this very cycle must survive being served, or it would be
                        // swallowed by this clear -- so carry it rather than assigning zero.
                        cfg_pending <= cfg_rise;
                        cfg_ref_r   <= cfg_ref_pend;
                        is_init     <= 1'b1;
                        burst_idx   <= {BST_W{1'b0}};
                        // The device may still be calibrating, since cfg_apply exists for one powered after
                        // the FPGA; losing the configuration here would fail the very case it serves.
                        gap_cnt     <= START_INIT;
                        state       <= ST_GAP;
                    end else if (in_valid) begin
                        for (i = 0; i < N; i = i + 1) code_r[i] <= code_of(i);
                        is_init   <= 1'b0;
                        burst_idx <= {BST_W{1'b0}};
                        gap_cnt   <= GAP_INIT;
                        state     <= ST_GAP;
                    end
                end

                ST_GAP: begin
                    if (gap_cnt != 0) begin
                        gap_cnt <= gap_cnt - 1'b1;
                    end else begin
                        // io_sclk stays parked for one more period, so the first falling edge lands a full
                        // period after CSB falls. Presenting the MSB here rather than at the first launch
                        // edge gives it that whole period of setup; the launch below re-assigns the same
                        // value, so nothing moves on that edge.
                        io_cs_n <= 1'b0;
                        io_mosi <= next_frame[23];
                        ph      <= {PH_W{1'b0}};
                        bit_cnt <= {BIT_W{1'b0}};
                        shreg   <= next_frame;
                        state   <= ST_BURST;
                    end
                end

                ST_BURST: begin
                    ph <= ph_next;
                    // `shifting` goes false as the last bit is launched, but the high phase must still run to
                    // its end or the final pulse -- the one the device executes on -- becomes a one-cycle runt
                    // that breaks tCH and tSCLK once a clk cycle is under 8 ns. The added term is
                    // constant-false at SCLK_DIV = 2, where PH_HALF is already PH_LAST.
                    /* verilator lint_off CMPCONST */
                    io_sclk <= (ph_next >= PH_HALF) && (shifting || (ph_next > PH_HALF));
                    /* verilator lint_on CMPCONST */
                    if (launch) begin
                        io_mosi <= shreg[23];
                        bit_cnt <= bit_cnt + 1'b1;
                        shreg   <= {shreg[22:0], 1'b0};
                    end
                    if (burst_end) begin
                        // HALF cycles -- one io_sclk half period -- have elapsed since the last falling edge,
                        // which satisfies tCSH1 without adding a further io_sclk edge.
                        io_cs_n <= 1'b1;
                        io_mosi <= 1'b0;
                        ph      <= {PH_W{1'b0}};
                        if ((burst_idx + 1'b1) >= num_bursts) begin
                            if (is_init) init_done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            burst_idx <= burst_idx + 1'b1;
                            gap_cnt   <= GAP_INIT;
                            state     <= ST_GAP;
                        end
                    end
                end

                default: begin  // Unreachable.
                    cfg_pending <= 1'b0;
                    io_sclk   <= 1'b0;
                    io_cs_n   <= 1'b1;
                    io_mosi   <= 1'b0;
                    is_init   <= 1'b1;
                    init_done <= 1'b0;
                    burst_idx <= {BST_W{1'b0}};
                    gap_cnt   <= GAP_INIT;
                    state     <= ST_GAP;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
