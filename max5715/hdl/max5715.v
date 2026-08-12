// Driver for the MAX5715 quad-channel 12-bit voltage-output SPI DAC.
// Also usable with the MAX5713 (8-bit) and MAX5714 (10-bit), whose codes occupy the same left-justified
// field -- the surplus low bits are simply ignored by those parts.
//
// The input word is always aligned to the top of the 12-bit code field. A word wider than 12 bits has its
// surplus low bits discarded; a narrower one has the missing low bits zero-filled. Either way the full-scale
// point is the same, so W only sets the resolution, never the range.
//
// Signedness is per channel and is part of the sample: in_signed is latched together with in_words, so a
// channel carrying a two's complement quantity and one carrying a straight binary quantity can share the
// device. Tying a bit to a constant costs nothing -- the bias is one exclusive-or on the code's most
// significant bit, which folds away when the select is constant. Equally, in_signed can simply be wired to
// zero and the correction applied upstream by inverting the sign bit of the data itself; the two are the same
// gate, so use whichever sits more naturally in the calling design.
//
// The device is configured in Power Mode = Normal, all DAC's selected, all channels within the same chip are
// updated synchronously; if daisy-chaining is used, no attempt to synchronize across the chips is made.
// The initial configuration is set up once after the rst input is deasserted, and again whenever cfg_apply
// asks for it; while a configuration sequence is in progress, in_ready remains deasserted.
// The in_ready output also remains deasserted while an update transaction is in progress.
//
// CONFIGURATION AT RUNTIME
//
// The sequence begins with SW_RESET, so it CLEARS the device's CODE and DAC registers: every output returns to
// zero scale and stays there until the next accepted sample. The driver's own copy of the codes is untouched,
// but it does not resend them by itself, so follow a reconfiguration with an update if the outputs matter.
//
// cfg_apply exists because the device's registers can outlive this module's knowledge of them: if the DAC's
// supply comes up later than the FPGA's, the automatic post-reset configuration lands on a device that is not
// yet listening, and the part is left in its power-on default of an external reference.
// Pulsing cfg_apply once the supply is known good repairs that, and it costs nothing when unused.
// Unlike the post-reset sequence it does not wait out STARTUP_CYCLES since by then the device has finished calibrating.
//
// Tying cfg_apply low is perfectly acceptable and is the right default: the device is then configured exactly
// once, by the automatic post-reset sequence, which is the behaviour of a system whose DAC supply is up before
// reset is released.
//
// A cfg_apply raised in the same cycle as an accepted sample does not outrank it -- the sample was offered while
// in_ready was high, so the handshake obliges the driver to send it, and the configuration follows. Since the
// configuration begins with SW_RESET, it then clears what that sample just wrote. Raise cfg_apply when idle.
//
// The DAC latch is left in its default latched mode (CONFIG LD_EN=0) and the hardware LDAC/CLR pins are not
// used, so the host only needs the three signals driven here. Each update writes the CODE register of every
// channel and then issues LOAD_ALL, which transfers every CODE register into its DAC register in one operation;
// that is what makes the channels of a chip step simultaneously. LOAD_ALL is preferred over CODEn_LOAD_ALL
// because the latter deliberately skips channels whose CODE register has not changed since the previous load.
//
// SERIAL CLOCK
//
// io_sclk is generated internally by dividing clk by SCLK_DIV, and it only toggles while a frame is being
// transmitted -- it is parked low whenever io_cs_n is deasserted. Keeping it quiet between updates avoids
// injecting digital feedthrough into the analog outputs, and the DAC ignores SCLK while CSB is high anyway.
//
// Within one io_sclk period a phase counter runs 0 .. SCLK_DIV-1; io_sclk is low over the first half and high
// over the second. io_mosi is launched on the very clk edge that raises io_sclk, so the falling edge half a
// period later -- the edge on which the DAC samples DIN -- sees data that has been stable for SCLK_DIV/2 clk
// cycles and stays stable for SCLK_DIV/2 more. Setup and hold are therefore equal, which maximises the smaller
// of the two. io_cs_n is asserted one full io_sclk period ahead of the first falling edge:
//
//            ______________                                                          _______________
//   io_cs_n                \________________________________________________________/
//                            _______         _______         _______         _______
//   io_sclk  _______________/       \_______/       \_______/       \_______/       \________________
//                                   ^               ^               ^               ^  DIN sampled here
//            _______________ _______________ _______________ _______________ ________________________
//   io_mosi  _______________X____B23________X____B22________X_____..._______X____B0__________________
//
// At clk = 100 MHz with SCLK_DIV = 2 (io_sclk = 50 MHz, the rated maximum of the part) the margins against
// the datasheet limits are: tSCLK 20 ns (=20 min), tCH/tCL 10 ns (=8 min), tDS 10 ns (=5 min),
// tDH 10 ns (=4.5 min), tCSS0 20 ns (=8 min), tCSH1 10 ns (=0 min), tCSPW 130 ns (=20 min),
// tCSF 140 ns (=100 min). Note that fSCLK may only reach 50 MHz when VDDIO is at least 2.7 V.
//
// CLK_HZ must state the real frequency of clk, because the intervals the DAC specifies in absolute time --
// tCSF, tCSPW, tSCLK, tCH, tCL and the power-up calibration window -- are derived from it. Everything that
// can be checked at elaboration is checked there, including the data sheet's 20 MHz ceiling on daisy-chained
// operation, so an unusable combination of CLK_HZ and SCLK_DIV fails to elaborate instead of misbehaving.
//
// After power-up the device spends about 200 us calibrating and ignores every command issued during that
// time, so the configuration sequence is held off for STARTUP_CYCLES clk cycles after reset is released.

`default_nettype none

module max5715#(
    parameter W        = 12,    // Word width; aligned to the top of the code field, zero-filled or truncated
    parameter N        = 4,     // Number of DAC channels; >4 if multiple units daisy-chained (see datasheet)
    parameter CLK_HZ   = 100_000_000,   // Real frequency of clk; the absolute-time IO limits derive from it
    parameter SCLK_DIV = 2,     // clk-to-io_sclk division factor; shall be even and at least 2
    // Cycles to hold io_cs_n deasserted after reset before configuring the device, covering its power-up
    // calibration. Defaults to 400 us, twice the typical figure; may be shortened in simulation.
    parameter STARTUP_CYCLES = (CLK_HZ + 2499) / 2500
)(
    input wire clk,
    input wire rst,

    // DAC configuration options. Sampled continuously until the first configuration completes, and again
    // whenever cfg_apply requests a reconfiguration.
    //
    // cfg_apply re-sends the whole configuration sequence, which begins with SW_RESET and therefore clears the
    // device's CODE and DAC registers -- every output returns to zero scale until the next accepted sample.
    // A single cycle is enough; the request, and cfg_ref as it stands at that moment,
    // are held until they can be served. Holding the input high does not queue further requests.
    input wire [1:0] cfg_ref,   // 00=ext, 01=2.500V, 10=2.048V, 11=4.096V
    input wire cfg_apply,

    // DAC inputs; all sampled and output synchronously.
    // in_signed is one bit per channel, latched with in_words:
    //      1 treats that word as two's complement and biases it so that zero sits at Vref/2,
    //      0 treats it as straight binary.
    input  wire in_valid,               // Sample in_words and update DAC ASAP; ignored while in_ready is deasserted
    output wire in_ready,               // High when ready to accept the next sample (idle)
    input  wire [(W*N)-1:0] in_words,   // Packed DAC words, MSb-aligned into the code field, #0=OUTA, #1=OUTB, ...
    input  wire [N-1:0] in_signed,

    // External IO pins.
    output reg io_sclk,         // DAC's SCLK; derived from clk, parked low while idle
    output reg io_cs_n,         // If daisy-chaining is used, connect to the CSB of the first DAC in the chain
    output reg io_mosi          // DAC's DIN
);
    // ------------------------------------------------ Geometry ------------------------------------------------

    // How much of each input word reaches the code field, and the power of two that lifts it into place.
    localparam TAKE = (W < 12) ? W : 12;
    localparam [11:0] FILL_SCALE = 12'd1 << (12 - TAKE);

    localparam CHANS_PER_CHIP = 4;                              // The MAX5715 is a quad DAC
    localparam NUM_CHIPS      = (N + CHANS_PER_CHIP - 1) / CHANS_PER_CHIP;
    localparam NCH            = NUM_CHIPS * CHANS_PER_CHIP;     // Channel count padded up to whole chips
    localparam FRAME_BITS     = 24;                             // Every SPI operation is one 24-bit word
    localparam BURST_BITS     = FRAME_BITS * NUM_CHIPS;         // One CSB assertion feeds every chip in the chain
    localparam HALF           = SCLK_DIV / 2;

    // Whole clk cycles spanning each interval the data sheet states in absolute time, rounded up. CLK_HZ has
    // to stay below about 2e9 for these expressions to remain inside 32-bit integer arithmetic.
    localparam CYC_8NS   = (CLK_HZ + 124_999_999) / 125_000_000;
    localparam CYC_20NS  = (CLK_HZ +  49_999_999) /  50_000_000;
    localparam CYC_50NS  = (CLK_HZ +  19_999_999) /  20_000_000;
    localparam CYC_100NS = (CLK_HZ +   9_999_999) /  10_000_000;

    // Cycles io_cs_n stays deasserted between bursts. tCSF runs from the last falling edge, which precedes the
    // rise of io_cs_n by HALF cycles, and io_cs_n falls one cycle after the counter expires, so the interval
    // actually realised is HALF + GAP_CYCLES + 1 cycles. tCSPW gets GAP_CYCLES + 1.
    localparam GAP_CYCLES = CYC_100NS + 2;

    // A burst carries one frame to each chip. An update is one CODEn burst per channel of a chip, then LOAD_ALL.
    localparam CODE_BURSTS = (N >= CHANS_PER_CHIP) ? CHANS_PER_CHIP : N;
    localparam UPD_BURSTS  = CODE_BURSTS + 1;
    localparam INIT_BURSTS = 4;                                 // SW_RESET, POWER, CONFIG, REF

    localparam PH_W   = $clog2(SCLK_DIV);                       // SCLK_DIV >= 2 makes this at least 1
    localparam BIT_W  = $clog2(BURST_BITS + 1);
    localparam CHIP_W = $clog2(NUM_CHIPS + 1);                  // Must also hold NUM_CHIPS itself
    localparam GAP_MAX = (STARTUP_CYCLES > GAP_CYCLES) ? STARTUP_CYCLES : GAP_CYCLES;
    localparam GAP_W  = $clog2(GAP_MAX + 1);
    localparam BST_W  = $clog2(((INIT_BURSTS > UPD_BURSTS) ? INIT_BURSTS : UPD_BURSTS) + 1);

    // Sized forms of the above so that the comparisons in the engine need no width casts. The implicit
    // narrowing of these 32-bit constant expressions is exactly what is intended, hence the pragma.
    /* verilator lint_off WIDTHTRUNC */
    localparam [PH_W-1:0]  PH_LAST    = SCLK_DIV - 1;
    localparam [PH_W-1:0]  PH_HALF    = HALF;
    localparam [BIT_W-1:0] BIT_LAST   = BURST_BITS;
    localparam [GAP_W-1:0] GAP_INIT   = GAP_CYCLES;
    localparam [GAP_W-1:0] START_INIT = STARTUP_CYCLES;
    localparam [BST_W-1:0] BST_INIT   = INIT_BURSTS;
    localparam [BST_W-1:0] BST_UPD    = UPD_BURSTS;
    localparam [4:0]       FRAME_LAST = FRAME_BITS - 1;
    /* verilator lint_on WIDTHTRUNC */

    // Illegal parameter combinations instantiate a module that does not exist, so elaboration stops with the
    // reason in the module name -- in synthesis as well as in simulation, unlike a runtime $fatal.
    generate
        if (W < 1)                                   begin : g_chk_w      max5715_error_W_lt_1 e();   end
        // Without this, CLK_HZ = 0 makes every CYC_* zero and all the timing guards below pass vacuously.
        if (CLK_HZ < 1)                              begin : g_chk_hz     max5715_error_CLK_HZ_lt_1 e(); end
        if (CLK_HZ > 2_000_000_000)                  begin : g_chk_hzmax  max5715_error_CLK_HZ_over_2GHz e(); end
        if (N < 1)                                   begin : g_chk_n      max5715_error_N_lt_1 e();   end
        // An odd divisor would trade tCH against tCL and shrink one of the setup/hold margins for no benefit.
        if ((SCLK_DIV < 2) || ((SCLK_DIV % 2) != 0)) begin : g_chk_div    max5715_error_SCLK_DIV_odd e(); end
        if (SCLK_DIV < CYC_20NS)                     begin : g_chk_fmax   max5715_error_SCLK_over_50MHz e(); end
        if (HALF < CYC_8NS)                          begin : g_chk_half   max5715_error_SCLK_half_under_8ns e(); end
        // Note 12 of the data sheet caps daisy-chained operation at 20 MHz whatever VDDIO is.
        if ((NUM_CHIPS > 1) && (SCLK_DIV < CYC_50NS)) begin : g_chk_chain max5715_error_chain_over_20MHz e(); end
        if (STARTUP_CYCLES < 1)                      begin : g_chk_start  max5715_error_STARTUP_lt_1 e(); end
    endgenerate

    // ------------------------------------------------ Frames ------------------------------------------------

    // Command bytes are B[23:16]; see Table 2 of the datasheet. DAC codes are left justified into B[15:4].
    localparam [23:0] FRM_SW_RESET = 24'h51_0000;   // All CODE, DAC and control registers to their defaults
    localparam [23:0] FRM_POWER    = 24'h40_0F00;   // Power mode Normal, all four DACs selected (B[11:8])
    localparam [23:0] FRM_CONFIG   = 24'h68_0000;   // All DACs, LD_EN=0: DAC latch operational, not transparent
    localparam [23:0] FRM_LOAD_ALL = 24'h81_0000;   // Update every DAC register from its CODE register
    localparam [23:0] FRM_NO_OP    = 24'h90_0000;   // B[23:20]=1001 has no effect on the device

    reg [1:0]  cfg_ref_r;
    reg [11:0] code_r [0:NCH-1];

    // Blocking assignments to function locals are the normal Verilog idiom; see fir.v for the same pragma.
    // verilator lint_off BLKSEQ

    // Extracts the DAC code for the given channel out of in_words, applying the signed bias. The index is
    // clamped so that the part-select stays in range for the padding channels of an incompletely used chip.
    function automatic [11:0] code_of;
        input integer idx;
        integer sel;
        begin
            sel = (idx < N) ? idx : 0;
            // Multiplying by a constant power of two is the zero-fill: it shifts the word up to the top of the
            // code field and costs nothing but wiring. Two's complement to the device's straight binary is
            // then just an inversion of the top bit.
            code_of = (in_words[(W*sel) + (W-1) -: TAKE] * FILL_SCALE) ^ (in_signed[sel] ? 12'h800 : 12'h000);
        end
    endfunction

    // The 24-bit frame destined for the given chip during the given burst of the given sequence.
    function automatic [23:0] frame_of;
        input              is_init;
        input [BST_W-1:0]  burst;
        input [CHIP_W-1:0] chip;
        integer ch;
        integer burst_i;
        integer chip_i;
        begin
            // Widen both indices to integer so that the arithmetic below cannot overflow a narrow counter.
            /* verilator lint_off WIDTHEXPAND */
            burst_i = burst;
            chip_i  = chip;
            /* verilator lint_on WIDTHEXPAND */
            ch = (chip_i * CHANS_PER_CHIP) + burst_i;
            if (is_init) begin
                case (burst)
                    0:       frame_of = FRM_SW_RESET;
                    1:       frame_of = FRM_POWER;
                    2:       frame_of = FRM_CONFIG;
                    // REF: B[23:20]=0111 command, B19=0, B18=1 keeps the reference powered even in standby,
                    // B[17:16] selects external or one of the three internal reference voltages.
                    3:       frame_of = {6'b011101, cfg_ref_r, 16'h0000};
                    default: frame_of = FRM_NO_OP;
                endcase
            end else if (burst_i >= CODE_BURSTS) begin
                frame_of = FRM_LOAD_ALL;
            end else if (ch < N) begin
                // CODEn: B[23:20]=0000 command, B[19:16] selects the channel within the chip.
                frame_of = {6'b000000, burst[1:0], code_r[ch], 4'h0};
            end else begin
                frame_of = FRM_NO_OP;                   // Channel not present -- leave that DAC untouched
            end
        end
    endfunction

    // verilator lint_on BLKSEQ

    // ------------------------------------------------ Engine ------------------------------------------------

    localparam ST_IDLE  = 2'd0;     // io_cs_n deasserted, io_sclk parked, waiting for in_valid
    localparam ST_GAP   = 2'd1;     // io_cs_n deasserted, io_sclk parked, waiting out GAP_CYCLES before a burst
    localparam ST_BURST = 2'd2;     // io_cs_n asserted, shifting BURST_BITS bits out

    reg [1:0]        state;
    reg              is_init;       // The sequence being transmitted is the post-reset configuration
    reg              init_done;
    reg [BST_W-1:0]  burst_idx;
    reg [CHIP_W-1:0] chip_idx;
    reg [PH_W-1:0]   ph;
    reg [BIT_W-1:0]  bit_cnt;       // Bits launched so far within the current burst
    reg [4:0]        bit_in_frame;
    reg [GAP_W-1:0]  gap_cnt;
    reg [23:0]       shreg;
    reg              cfg_apply_r;   // Previous cfg_apply, so a held-high input cannot loop the sequence
    reg              cfg_pending;
    reg [1:0]        cfg_ref_pend;  // cfg_ref as it stood when the request was made, not when it is served

    wire [BST_W-1:0] num_bursts = is_init ? BST_INIT : BST_UPD;
    wire [PH_W-1:0]  ph_next    = (ph == PH_LAST) ? {PH_W{1'b0}} : (ph + 1'b1);
    wire             shifting   = bit_cnt < BIT_LAST;
    wire             launch     = (ph_next == PH_HALF) && shifting;
    wire             burst_end  = (ph_next == PH_HALF) && !shifting;
    wire             last_bit   = bit_in_frame == FRAME_LAST;
    wire             cfg_rise   = cfg_apply && !cfg_apply_r;

    // init_done is strictly redundant today because reset enters ST_GAP and ST_IDLE is first reached only at
    // the end of a sequence, but gating on it makes in_ready correct by construction rather than by a
    // non-local argument about which states are reachable when. Readiness is also withdrawn while a
    // configuration request is outstanding: that request has to run first, and the handshake forbids ignoring
    // a sample that was offered while in_ready was high.
    assign in_ready = init_done && (state == ST_IDLE) && !cfg_pending;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_GAP;
            is_init      <= 1'b1;
            init_done    <= 1'b0;
            burst_idx    <= {BST_W{1'b0}};
            chip_idx     <= {CHIP_W{1'b0}};
            ph           <= {PH_W{1'b0}};
            bit_cnt      <= {BIT_W{1'b0}};
            bit_in_frame <= 5'd0;
            gap_cnt      <= START_INIT;     // The device ignores commands while it calibrates after power-up
            shreg        <= 24'h000000;
            cfg_ref_r    <= cfg_ref;
            cfg_apply_r  <= cfg_apply;
            cfg_pending  <= 1'b0;
            cfg_ref_pend <= cfg_ref;
            io_sclk      <= 1'b0;
            io_cs_n      <= 1'b1;
            io_mosi      <= 1'b0;
            for (i = 0; i < NCH; i = i + 1) code_r[i] <= 12'h000;
        end else begin
            // Sampled up to the point where the configuration completes, so a caller may present cfg_ref
            // either during reset or while the power-up hold-off runs. Frozen from then on, until cfg_apply.
            if (!init_done) cfg_ref_r <= cfg_ref;

            cfg_apply_r <= cfg_apply;
            if (cfg_rise) begin
                cfg_pending  <= 1'b1;
                // The reference has to be captured now: a request raised during a burst is not served until
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
                        gap_cnt     <= GAP_INIT;
                        state       <= ST_GAP;
                    end else if (in_valid) begin
                        for (i = 0; i < NCH; i = i + 1) code_r[i] <= code_of(i);
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
                        // Assert CSB and park io_sclk low for one more period; the first falling edge is thus
                        // a full io_sclk period after CSB falls, which is what gives tCSS0 its margin.
                        io_cs_n      <= 1'b0;
                        ph           <= {PH_W{1'b0}};
                        bit_cnt      <= {BIT_W{1'b0}};
                        bit_in_frame <= 5'd0;
                        chip_idx     <= {CHIP_W{1'b0}};
                        shreg        <= frame_of(is_init, burst_idx, {CHIP_W{1'b0}});
                        state        <= ST_BURST;
                    end
                end

                ST_BURST: begin
                    ph <= ph_next;
                    // The high phase must be seen through to its end even though `shifting` has already gone
                    // false after the last bit was launched, otherwise the final pulse of every frame -- whose
                    // falling edge is the one the device executes on -- would be a runt one cycle wide, which
                    // breaks tCH and tSCLK once a clk cycle is shorter than 8 ns. At SCLK_DIV = 2 the added
                    // term can never be true (PH_HALF equals PH_LAST), so that case is unaffected.
                    // The added term is deliberately constant-false at SCLK_DIV = 2, where PH_HALF is already
                    // PH_LAST and the untruncated pulse is one cycle wide anyway.
                    /* verilator lint_off CMPCONST */
                    io_sclk <= (ph_next >= PH_HALF) && (shifting || (ph_next > PH_HALF));
                    /* verilator lint_on CMPCONST */
                    if (launch) begin
                        io_mosi <= shreg[23];
                        bit_cnt <= bit_cnt + 1'b1;
                        if (last_bit) begin
                            bit_in_frame <= 5'd0;
                            chip_idx     <= chip_idx + 1'b1;
                            shreg        <= frame_of(is_init, burst_idx, chip_idx + 1'b1);
                        end else begin
                            bit_in_frame <= bit_in_frame + 1'b1;
                            shreg        <= {shreg[22:0], 1'b0};
                        end
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

                // Unreachable, but a corrupted state must not leave the pins driving a half-finished frame.
                // Park them and reconfigure the device from scratch, since its registers cannot be trusted either.
                default: begin
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
