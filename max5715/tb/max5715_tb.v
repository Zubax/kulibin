// Testbench for max5715. Run via `fusesoc run --target=sim zubax:kulibin:max5715`,
// or with Verilator via `make verilate` from the repository root.
//
// The bench contains a behavioural model of the MAX5715 that doubles as a protocol and timing checker: it
// decodes every 24-bit frame, applies it to a register model of the chip, and fails on any datasheet timing
// violation measured at its own pins. Several harnesses instantiate the driver with different parameters,
// including the 100 MHz / 50 MHz target operating point and a two-chip daisy chain.
//
// The analog transfer function is deliberately not modelled here -- the code-to-voltage relationship is
// verified against the real part on the bench, see max5715/tools/hw_test.py.

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

// ================================================================================================= DAC MODEL

// Register-level model of one MAX5715, including the daisy-chain RDY output and the SPI timing checks.
// Blocking assignments are used throughout because the decode has to be sequential; that is normal for a
// behavioural model but Verilator flags it by default.
/* verilator lint_off BLKSEQ */
module max5715_model#(
    parameter ID = 0,               // Reported in diagnostics so a failure can be traced to one chip
    // SPI timing limits from the MAX5713/MAX5714/MAX5715 data sheet, in nanoseconds.
    parameter real T_SCLK_MIN = 20.0,
    parameter real T_CH_MIN   = 8.0,
    parameter real T_CL_MIN   = 8.0,
    parameter real T_DS_MIN   = 5.0,
    parameter real T_DH_MIN   = 4.5,
    parameter real T_CSS0_MIN = 8.0,
    parameter real T_CSH1_MIN = 0.0,
    parameter real T_CSPW_MIN = 20.0,
    parameter real T_CSF_MIN  = 100.0
)(
    input  wire csb,
    input  wire sclk,
    input  wire din,
    output reg  rdy,                // Pulled low on the 24th falling edge; feeds the next chip's CSB

    // Observable state, packed because Verilog-2001 has no unpacked array ports.
    output wire [47:0]  dac_flat,   // DAC registers, {D,C,B,A}, 12 bits each
    output wire [47:0]  code_flat,  // CODE registers, {D,C,B,A}
    output wire [191:0] log_flat,   // The last 8 executed frames, index 0 = most recent
    output wire [15:0]  exec_cnt,   // Number of frames executed since time zero
    output wire [1:0]   ref_mode,
    output wire         ref_pwr,
    output wire [1:0]   pwr_mode,
    output wire         ld_en
);
    localparam LOG_DEPTH = 8;

    reg [11:0] code_m [0:3];
    reg [11:0] dac_m  [0:3];
    reg [23:0] log_m  [0:LOG_DEPTH-1];
    reg [1:0]  ref_mode_m;
    reg        ref_pwr_m;
    reg [1:0]  pwr_mode_m;
    reg        ld_en_m;
    reg [15:0] n_exec;

    reg [22:0] shreg;              // The 24th bit is consumed as it arrives, so only 23 need storing
    integer    edges;               // Falling edges seen so far in the current CSB-low window
    integer    executed;            // Frames executed in the current window; must end up exactly 1

    real t_din;                     // Time of the last din transition
    real t_fall;                    // Time of the last sclk falling edge
    real t_rise;                    // Time of the last sclk rising edge
    real t_csb_fall;
    real t_csb_rise;
    real t_win_last_fall;           // Last falling edge of the previous window, for tCSF
    reg  armed;                     // Suppresses checks until the first frame starts

    integer i;

    assign exec_cnt = n_exec;
    assign ref_mode = ref_mode_m;
    assign ref_pwr  = ref_pwr_m;
    assign pwr_mode = pwr_mode_m;
    assign ld_en    = ld_en_m;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_state
            assign dac_flat[12*gi +: 12]  = dac_m[gi];
            assign code_flat[12*gi +: 12] = code_m[gi];
        end
        for (gi = 0; gi < LOG_DEPTH; gi = gi + 1) begin : g_log
            assign log_flat[24*gi +: 24] = log_m[gi];
        end
    endgenerate

    initial begin
        rdy        = 1'b1;
        shreg      = 23'h000000;
        edges      = 0;
        executed   = 0;
        n_exec     = 16'd0;
        ref_mode_m = 2'b00;         // Power-on defaults per the data sheet
        ref_pwr_m  = 1'b0;
        pwr_mode_m = 2'b00;
        ld_en_m    = 1'b0;
        t_din      = 0.0;
        t_fall     = 0.0;
        t_rise     = 0.0;
        t_csb_fall = 0.0;
        t_csb_rise = 0.0;
        t_win_last_fall = 0.0;
        armed      = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            code_m[i] = 12'h000;
            dac_m[i]  = 12'h000;    // Power-on reset drives every output to zero scale
        end
        for (i = 0; i < LOG_DEPTH; i = i + 1) log_m[i] = 24'h000000;
    end

    // Applies one 24-bit SPI operation. $fatal on anything the data sheet marks reserved, so that a driver
    // emitting a malformed command cannot pass silently.
    task automatic execute;
        input [23:0] f;
        reg [11:0] c;
        reg [3:0]  sel;             // Per-channel selection mask, {D,C,B,A}
        integer k;
        begin
            c = f[15:4];            // Codes are left justified into B[15:4]
            // Table 3: B18 or B19 set selects all DACs, otherwise B[17:16] is the channel number.
            if (f[19] || f[18]) sel = 4'b1111;
            else                sel = 4'b0001 << f[17:16];

            if (f[23:20] == 4'b0000) begin                          // CODEn
                for (k = 0; k < 4; k = k + 1) if (sel[k]) code_m[k] = c;
            end else if (f[23:20] == 4'b0001) begin                 // LOADn
                for (k = 0; k < 4; k = k + 1) if (sel[k]) dac_m[k] = code_m[k];
            end else if (f[23:20] == 4'b0010) begin                 // CODEn_LOAD_ALL
                for (k = 0; k < 4; k = k + 1) if (sel[k]) code_m[k] = c;
                for (k = 0; k < 4; k = k + 1) dac_m[k] = code_m[k];
            end else if (f[23:20] == 4'b0011) begin                 // CODEn_LOADn
                for (k = 0; k < 4; k = k + 1) if (sel[k]) begin
                    code_m[k] = c;
                    dac_m[k]  = c;
                end
            end else if (f[23:20] == 4'b0100) begin                 // POWER
                if (f[11:8] != 4'b0000) pwr_mode_m = f[17:16];
            end else if (f[23:16] == 8'h50) begin                   // SW_CLEAR
                for (k = 0; k < 4; k = k + 1) begin
                    code_m[k] = 12'h000;
                    dac_m[k]  = 12'h000;
                end
            end else if (f[23:16] == 8'h51) begin                   // SW_RESET
                for (k = 0; k < 4; k = k + 1) begin
                    code_m[k] = 12'h000;
                    dac_m[k]  = 12'h000;
                end
                ref_mode_m = 2'b00;
                ref_pwr_m  = 1'b0;
                pwr_mode_m = 2'b00;
                ld_en_m    = 1'b0;
            end else if (f[23:20] == 4'b0110) begin                 // CONFIG
                if (f[19] || (f[11:8] != 4'b0000)) ld_en_m = f[16];
            end else if (f[23:19] == 5'b01110) begin                // REF
                ref_pwr_m  = f[18];
                ref_mode_m = f[17:16];
            end else if (f[23:16] == 8'h80) begin                   // CODE_ALL
                for (k = 0; k < 4; k = k + 1) code_m[k] = c;
            end else if (f[23:16] == 8'h81) begin                   // LOAD_ALL
                for (k = 0; k < 4; k = k + 1) dac_m[k] = code_m[k];
            end else if (f[23:17] == 7'b1000001) begin              // CODE_ALL_LOAD_ALL
                for (k = 0; k < 4; k = k + 1) begin
                    code_m[k] = c;
                    dac_m[k]  = c;
                end
            end else if ((f[23:20] == 4'b1001) || (f[23:21] == 3'b101) || (f[23:22] == 2'b11)) begin
                // No operation; explicitly listed as having no effect on the device.
            end else begin
                $display("model %0d: reserved/unknown command %06h at %0t", ID, f, $realtime);
                $fatal;
            end

            for (k = LOG_DEPTH-1; k > 0; k = k - 1) log_m[k] = log_m[k-1];
            log_m[0] = f;
            n_exec   = n_exec + 16'd1;
            executed = executed + 1;
        end
    endtask

    task automatic fail;
        input [8*40-1:0] what;
        input real       got;
        input real       need;
        begin
            $display("model %0d: %0s violation at %0t: %0.3f ns, need >= %0.3f ns", ID, what, $realtime, got, need);
            $fatal;
        end
    endtask

    always @(negedge csb) begin
        if (armed) begin
            if (($realtime - t_csb_rise) < T_CSPW_MIN) fail("tCSPW", $realtime - t_csb_rise, T_CSPW_MIN);
            if (($realtime - t_win_last_fall) < T_CSF_MIN) fail("tCSF", $realtime - t_win_last_fall, T_CSF_MIN);
        end
        t_csb_fall = $realtime;
        edges      = 0;
        executed   = 0;
        armed      = 1'b1;
    end

    always @(posedge csb) begin
        if (armed) begin
            // A window must carry a whole number of frames, and exactly one of them must have been executed
            // by this chip -- everything past its own 24th falling edge belongs to the next chip in the chain.
            `REQUIRE((edges % 24) == 0);
            `REQUIRE(edges >= 24);
            `REQUIRE(executed == 1);
            if (($realtime - t_fall) < T_CSH1_MIN) fail("tCSH1", $realtime - t_fall, T_CSH1_MIN);
            t_win_last_fall = t_fall;
        end
        t_csb_rise = $realtime;
        rdy        = 1'b1;
    end

    always @(posedge sclk) begin
        if (!csb && (edges > 0)) begin
            if (($realtime - t_fall) < T_CL_MIN) fail("tCL", $realtime - t_fall, T_CL_MIN);
        end
        t_rise = $realtime;
    end

    always @(negedge sclk) begin
        if (!csb) begin
            if (($realtime - t_din) < T_DS_MIN) fail("tDS", $realtime - t_din, T_DS_MIN);
            if (($realtime - t_rise) < T_CH_MIN) fail("tCH", $realtime - t_rise, T_CH_MIN);
            if (edges > 0) begin
                if (($realtime - t_fall) < T_SCLK_MIN) fail("tSCLK", $realtime - t_fall, T_SCLK_MIN);
            end else begin
                if (($realtime - t_csb_fall) < T_CSS0_MIN) fail("tCSS0", $realtime - t_csb_fall, T_CSS0_MIN);
            end
            t_fall      = $realtime;
            if (edges == 23) begin
                execute({shreg, din});
                rdy = 1'b0;         // Enables the next chip in the chain from the 25th falling edge onwards
            end
            shreg = {shreg[21:0], din};
            edges = edges + 1;
        end else begin
            t_fall = $realtime;
        end
    end

    always @(din) begin
        if (armed && !csb && (edges > 0) && (($realtime - t_fall) < T_DH_MIN)) begin
            fail("tDH", $realtime - t_fall, T_DH_MIN);
        end
        t_din = $realtime;
    end
endmodule
/* verilator lint_on BLKSEQ */

// =================================================================================================== HARNESS

// One driver instance, a chain of behavioural chips, the stimulus and the checks. Asserts `done` when finished.
module max5715_harness#(
    parameter ID       = 0,
    parameter SWEEP_CFG = 0,        // Sweep the cfg_apply/service coincidence; slow, so one harness does it
    parameter SIGNED_MASK = 0,      // Initial value driven on in_signed; varied at runtime by the stimulus
    parameter W        = 12,
    parameter N        = 4,
    parameter CLK_HZ   = 100_000_000,
    parameter SCLK_DIV = 2,
    parameter STARTUP_CYCLES = 37    // Deliberately not a round number, so an off-by-one cannot hide
)(
    input  wire clk,
    output reg  done
);
    localparam NUM_CHIPS   = (N + 3) / 4;
    localparam CODE_BURSTS = (N >= 4) ? 4 : N;
    localparam UPD_BURSTS  = CODE_BURSTS + 1;
    localparam INIT_BURSTS = 4;
    // The driver aligns each word to the top of the code field, zero-filling or truncating the low bits.
    // Roughly how long an update occupies the engine, used to bracket the cfg_apply coincidence sweep.
    localparam GAP_C      = ((CLK_HZ + 9_999_999) / 10_000_000) + 2;
    localparam UPD_CYCLES = UPD_BURSTS * ((SCLK_DIV * 25) + GAP_C + 2);
    localparam TAKE = (W < 12) ? W : 12;
    localparam [11:0] FILL_SCALE = 12'd1 << (12 - TAKE);

    localparam [23:0] FRM_SW_RESET = 24'h51_0000;
    localparam [23:0] FRM_POWER    = 24'h40_0F00;
    localparam [23:0] FRM_CONFIG   = 24'h68_0000;
    localparam [23:0] FRM_LOAD_ALL = 24'h81_0000;
    localparam [23:0] FRM_NO_OP    = 24'h90_0000;

    reg              rst;
    reg  [1:0]       cfg_ref;
    reg              cfg_apply;
    reg              in_valid;
    reg  [(W*N)-1:0] in_words;
    reg  [N-1:0]     in_signed;
    wire             in_ready;
    wire             io_sclk;
    wire             io_cs_n;
    wire             io_mosi;

    max5715#(
        .W(W), .N(N), .CLK_HZ(CLK_HZ), .SCLK_DIV(SCLK_DIV), .STARTUP_CYCLES(STARTUP_CYCLES)
    ) dut (
        .clk(clk), .rst(rst), .cfg_ref(cfg_ref), .cfg_apply(cfg_apply),
        .in_valid(in_valid), .in_ready(in_ready), .in_words(in_words), .in_signed(in_signed),
        .io_sclk(io_sclk), .io_cs_n(io_cs_n), .io_mosi(io_mosi)
    );

    // The chain: chip 0 is selected by the driver, every later chip by its predecessor's RDY. The RDY of the
    // last chip has nowhere to go, which is exactly how a real chain terminates.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [NUM_CHIPS:0]   csb_chain;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [47:0]          chip_dac  [0:NUM_CHIPS-1];
    wire [47:0]          chip_code [0:NUM_CHIPS-1];
    wire [191:0]         chip_log  [0:NUM_CHIPS-1];
    wire [15:0]          chip_exec [0:NUM_CHIPS-1];
    wire [1:0]           chip_ref  [0:NUM_CHIPS-1];
    wire                 chip_rpwr [0:NUM_CHIPS-1];
    wire [1:0]           chip_pwr  [0:NUM_CHIPS-1];
    wire                 chip_lden [0:NUM_CHIPS-1];

    assign csb_chain[0] = io_cs_n;

    genvar gc;
    generate
        for (gc = 0; gc < NUM_CHIPS; gc = gc + 1) begin : g_chip
            max5715_model#(.ID(gc)) m (
                .csb(csb_chain[gc]), .sclk(io_sclk), .din(io_mosi), .rdy(csb_chain[gc+1]),
                .dac_flat(chip_dac[gc]), .code_flat(chip_code[gc]), .log_flat(chip_log[gc]),
                .exec_cnt(chip_exec[gc]), .ref_mode(chip_ref[gc]), .ref_pwr(chip_rpwr[gc]),
                .pwr_mode(chip_pwr[gc]), .ld_en(chip_lden[gc])
            );
        end
    endgenerate

    // The serial clock must never move while the chip select is deasserted.
    reg quiet_armed;
    initial quiet_armed = 1'b0;
    always @(io_sclk) begin
        if (quiet_armed && (io_cs_n !== 1'b0)) begin
            $display("harness %0d: io_sclk moved while io_cs_n deasserted at %0t", ID, $realtime);
            $fatal;
        end
    end

    // Every io_sclk high phase must last exactly half an io_sclk period. The model's tCH check is in absolute
    // time and so cannot see a runt pulse while a clk cycle still exceeds 8 ns; this can, at any clock rate.
    integer sclk_hi;
    initial sclk_hi = 0;
    always @(posedge clk) begin
        if (io_sclk) begin
            sclk_hi <= sclk_hi + 1;
        end else begin
            if (quiet_armed && (sclk_hi != 0) && (sclk_hi != (SCLK_DIV / 2))) begin
                $display("harness %0d: io_sclk high for %0d clk cycles, expected %0d, at %0t",
                         ID, sclk_hi, SCLK_DIV / 2, $realtime);
                $fatal;
            end
            sclk_hi <= 0;
        end
    end

    // No DAC register may take an intermediate value: the whole chip must step in one go on LOAD_ALL.
    reg [47:0] dac_before [0:NUM_CHIPS-1];
    reg [47:0] dac_expect [0:NUM_CHIPS-1];
    reg        atomic_armed;
    initial atomic_armed = 1'b0;
    generate
        for (gc = 0; gc < NUM_CHIPS; gc = gc + 1) begin : g_atomic
            always @(chip_dac[gc]) begin
                if (atomic_armed) begin
                    if ((chip_dac[gc] !== dac_before[gc]) && (chip_dac[gc] !== dac_expect[gc])) begin
                        $display("harness %0d chip %0d: partial DAC update %012h at %0t (before %012h, expect %012h)",
                                 ID, gc, chip_dac[gc], $realtime, dac_before[gc], dac_expect[gc]);
                        $fatal;
                    end
                end
            end
        end
    endgenerate

    // The DAC code the driver is expected to derive from one input word. Only the 12 most significant bits
    // take part, so for W > 12 the low bits are intentionally discarded.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [11:0] want_code;
        input [W-1:0] word;
        input         is_signed;
        begin
            want_code = (word[W-1 -: TAKE] * FILL_SCALE) ^ (is_signed ? 12'h800 : 12'h000);
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // The CODEn frame the driver is expected to emit for a channel of a chip.
    function automatic [23:0] want_codn;
        input [1:0]  ch;
        input [11:0] code;
        begin
            want_codn = {6'b000000, ch, code, 4'h0};
        end
    endfunction

    integer guard;

    // Drives one reset pulse with the given reference selection and waits for the configuration to complete.
    task automatic reset_with;
        input [1:0] refsel;
        reg [15:0] exec_at_reset;
        begin
            atomic_armed  = 1'b0;
            exec_at_reset = chip_exec[0];       // The model counts frames since time zero, never resetting
            rst          = 1'b1;
            cfg_ref      = refsel;
            cfg_apply    = 1'b0;
            in_valid     = 1'b0;
            repeat (4) @(negedge clk);
            `REQUIRE(!in_ready);
            rst         = 1'b0;
            quiet_armed = 1'b1;
            // The device ignores commands while it calibrates, so io_cs_n must stay parked for the whole
            // STARTUP_CYCLES window. This lands on the last cycle before io_cs_n is allowed to fall.
            repeat (STARTUP_CYCLES) @(negedge clk);
            `REQUIRE(io_cs_n === 1'b1);
            `REQUIRE(chip_exec[0] === exec_at_reset);
            guard       = 0;
            while (!in_ready) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 200000);
            end
            // in_ready may not rise before the whole configuration sequence has actually been executed.
            `REQUIRE(chip_exec[0] >= 16'd4);
        end
    endtask

    // Presents one sample and waits until the driver is idle again.
    task automatic send;
        input [(W*N)-1:0] words;
        begin
            @(negedge clk);
            guard = 0;
            while (!in_ready) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 200000);
            end
            in_words = words;
            in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            `REQUIRE(!in_ready);                    // The accept must have been taken on the intervening posedge
            guard = 0;
            while (!in_ready) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 200000);
            end
        end
    endtask

    // Snapshots the current DAC state and computes what it must become, arming the atomicity monitor.
    task automatic arm_expect;
        input [(W*N)-1:0] words;
        integer c;
        integer k;
        integer ch;
        reg [47:0] e;
        begin
            for (c = 0; c < NUM_CHIPS; c = c + 1) begin
                dac_before[c] = chip_dac[c];
                e = chip_dac[c];
                for (k = 0; k < 4; k = k + 1) begin
                    ch = (c * 4) + k;
                    if (ch < N) e[12*k +: 12] = want_code(words[(W*ch) + (W-1) -: W], in_signed[ch]);
                end
                dac_expect[c] = e;
            end
            atomic_armed = 1'b1;
        end
    endtask

    // Sends one sample and verifies every DAC register, plus the exact frame sequence that was used.
    task automatic send_and_check;
        input [(W*N)-1:0] words;
        integer c;
        integer k;
        integer ch;
        reg [15:0] exec0;
        begin
            arm_expect(words);
            exec0 = chip_exec[0];
            send(words);
            for (c = 0; c < NUM_CHIPS; c = c + 1) begin
                `REQUIRE(chip_dac[c] === dac_expect[c]);
                `REQUIRE(chip_code[c] === dac_expect[c]);    // LOAD_ALL copies CODE into DAC, so both agree
                // Every chip must have executed exactly the update sequence: one CODEn per existing channel
                // (NO-OP where the channel does not exist) and then a single LOAD_ALL.
                `REQUIRE(chip_log[c][24*0 +: 24] === FRM_LOAD_ALL);
                for (k = 0; k < CODE_BURSTS; k = k + 1) begin
                    ch = (c * 4) + k;
                    if (ch < N) begin
                        `REQUIRE(chip_log[c][24*(CODE_BURSTS-k) +: 24]
                                 === want_codn(k[1:0], want_code(words[(W*ch) + (W-1) -: W], in_signed[ch])));
                    end else begin
                        `REQUIRE(chip_log[c][24*(CODE_BURSTS-k) +: 24] === FRM_NO_OP);
                    end
                end
            end
            `REQUIRE(chip_exec[0] === (exec0 + UPD_BURSTS));
            atomic_armed = 1'b0;
        end
    endtask

    // Verifies the four-frame configuration sequence that follows a reset.
    task automatic check_init;
        input [1:0] refsel;
        integer c;
        begin
            for (c = 0; c < NUM_CHIPS; c = c + 1) begin
                `REQUIRE(chip_exec[c] >= 16'd4);
                `REQUIRE(chip_log[c][24*3 +: 24] === FRM_SW_RESET);
                `REQUIRE(chip_log[c][24*2 +: 24] === FRM_POWER);
                `REQUIRE(chip_log[c][24*1 +: 24] === FRM_CONFIG);
                `REQUIRE(chip_log[c][24*0 +: 24] === {6'b011101, refsel, 16'h0000});
                `REQUIRE(chip_ref[c]  === refsel);
                `REQUIRE(chip_rpwr[c] === 1'b1);        // The reference is asked to stay powered in standby
                `REQUIRE(chip_pwr[c]  === 2'b00);       // Normal power mode
                `REQUIRE(chip_lden[c] === 1'b0);        // DAC latch operational, not transparent
            end
        end
    endtask

    // ------------------------------------------------ Stimulus ------------------------------------------------

    reg [(W*N)-1:0] words;
/* verilator lint_off UNUSEDSIGNAL */
    reg [31:0]      pat;            // Scratch; only the low W bits are used
/* verilator lint_on UNUSEDSIGNAL */
    reg [15:0]      exec_snapshot;
    integer         idx;
    integer         rr;

    initial begin
        done         = 1'b0;
        rst          = 1'b1;
        cfg_ref      = 2'b01;
        cfg_apply    = 1'b0;
        in_valid     = 1'b0;
        in_words     = {(W*N){1'b0}};
        in_signed    = SIGNED_MASK[N-1:0];
        atomic_armed = 1'b0;

        // ---- Configuration sequence, exercising every reference selection ----
        for (rr = 0; rr < 4; rr = rr + 1) begin
            reset_with(rr[1:0]);
            check_init(rr[1:0]);
            // The configuration must run exactly once: idling must not emit anything further.
            exec_snapshot = chip_exec[0];
            repeat (50 * SCLK_DIV) @(negedge clk);
            `REQUIRE(chip_exec[0] === exec_snapshot);
            `REQUIRE(in_ready);
        end

        // ---- Zero scale, full scale, mid scale, and a distinct pattern per channel ----
        reset_with(2'b01);
        check_init(2'b01);

        words = {(W*N){1'b0}};
        send_and_check(words);

        words = {(W*N){1'b1}};
        send_and_check(words);

        for (idx = 0; idx < N; idx = idx + 1) begin
            pat = 32'h1 << (W - 1);                 // Most negative when signed, half scale when not
            words[(W*idx) + (W-1) -: W] = pat[W-1:0];
        end
        send_and_check(words);

        // A different pattern in every channel, so a swapped or duplicated channel cannot pass.
        for (idx = 0; idx < N; idx = idx + 1) begin
            pat = 32'h0005A3C7 + (idx * 32'h00011111);
            words[(W*idx) + (W-1) -: W] = pat[W-1:0];
        end
        send_and_check(words);

        // ---- Repeating the same sample must still produce a full, correct sequence ----
        send_and_check(words);

        // ---- Only one channel moves; the others must be rewritten with their unchanged codes ----
        words[W-1 -: W] = ~words[W-1 -: W];
        send_and_check(words);

        // ---- in_valid must be ignored while in_ready is low ----
        arm_expect(words);
        @(negedge clk);
        guard = 0;
        while (!in_ready) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        in_words = words;
        in_valid = 1'b1;
        @(negedge clk);
        `REQUIRE(!in_ready);
        // Hold in_valid asserted with different data for the whole transaction; it must have no effect.
        in_words = ~words;
        guard    = 0;
        while (!in_ready) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        in_valid = 1'b0;
        for (idx = 0; idx < NUM_CHIPS; idx = idx + 1) `REQUIRE(chip_dac[idx] === dac_expect[idx]);
        atomic_armed = 1'b0;
        @(negedge clk);

        // ---- Back-to-back updates with no idle time in between ----
        for (rr = 0; rr < 3; rr = rr + 1) begin
            for (idx = 0; idx < N; idx = idx + 1) begin
                pat = ((idx * 251) + (rr * 37));
                words[(W*idx) + (W-1) -: W] = pat[W-1:0];
            end
            send_and_check(words);
        end

        // ---- Signedness is per channel and travels with the sample ----
        // The same word must land on a different code depending on that channel's in_signed bit, and channels
        // configured differently must not interfere.
        for (rr = 0; rr < 2; rr = rr + 1) begin
            for (idx = 0; idx < N; idx = idx + 1) begin
                in_signed[idx] = ((idx + rr) % 2) != 0;
            end
            @(negedge clk);
            for (idx = 0; idx < N; idx = idx + 1) begin
                pat = 32'h1 << (W - 1);
                words[(W*idx) + (W-1) -: W] = pat[W-1:0];
            end
            send_and_check(words);
            for (idx = 0; idx < N; idx = idx + 1) begin
                // Signed most-negative maps to zero scale; the same bits read unsigned are half scale.
                `REQUIRE(chip_dac[idx / 4][12*(idx % 4) +: 12] === (in_signed[idx] ? 12'h000 : 12'h800));
            end
            words = {(W*N){1'b0}};
            send_and_check(words);
            for (idx = 0; idx < N; idx = idx + 1) begin
                `REQUIRE(chip_dac[idx / 4][12*(idx % 4) +: 12] === (in_signed[idx] ? 12'h800 : 12'h000));
            end
        end
        in_signed = SIGNED_MASK[N-1:0];
        @(negedge clk);

        // ---- cfg_apply must re-send the configuration without needing a reset ----
        // A single-cycle pulse is enough.
        words = {(W*N){1'b1}};
        send_and_check(words);
        for (idx = 0; idx < NUM_CHIPS; idx = idx + 1) `REQUIRE(chip_dac[idx] !== 48'h000000000000);
        exec_snapshot = chip_exec[0];
        cfg_ref       = 2'b11;
        @(negedge clk);
        cfg_apply = 1'b1;
        @(negedge clk);
        cfg_apply = 1'b0;
        guard = 0;
        while (!in_ready || (chip_exec[0] === exec_snapshot)) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        `REQUIRE(chip_exec[0] === (exec_snapshot + INIT_BURSTS));
        check_init(2'b11);
        // SW_RESET is part of the sequence, so the device's outputs return to zero scale.
        for (idx = 0; idx < NUM_CHIPS; idx = idx + 1) `REQUIRE(chip_dac[idx] === 48'h000000000000);

        // Held high, it must still produce exactly one sequence rather than looping for as long as it is high.
        exec_snapshot = chip_exec[0];
        cfg_ref       = 2'b10;
        @(negedge clk);
        cfg_apply = 1'b1;
        guard     = 0;
        while (!in_ready || (chip_exec[0] === exec_snapshot)) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        `REQUIRE(chip_exec[0] === (exec_snapshot + INIT_BURSTS));
        check_init(2'b10);
        exec_snapshot = chip_exec[0];
        repeat (80 * SCLK_DIV) @(negedge clk);       // Still asserted; nothing further may be sent
        `REQUIRE(chip_exec[0] === exec_snapshot);
        `REQUIRE(in_ready);
        cfg_apply = 1'b0;
        @(negedge clk);
        cfg_ref = 2'b01;

        // A request that coincides with an accepted sample does not outrank it: the sample was offered while
        // in_ready was high, so the handshake obliges the driver to take it, and the configuration follows.
        // The consequence is that the configuration's SW_RESET then clears what the sample just wrote, which
        // is why cfg_apply belongs in an idle moment.
        exec_snapshot = chip_exec[0];
        for (idx = 0; idx < N; idx = idx + 1) begin
            pat = 32'hFFFFFFFF >> 1;                // All ones with the top bit clear, at any width
            words[(W*idx) + (W-1) -: W] = pat[W-1:0];
        end
        @(negedge clk);
        cfg_apply = 1'b1;
        in_words  = words;
        in_valid  = 1'b1;
        @(negedge clk);
        cfg_apply = 1'b0;
        in_valid  = 1'b0;                       // Accepted on the posedge in between
        `REQUIRE(!in_ready);
        guard = 0;
        while (!in_ready) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        `REQUIRE(chip_exec[0] === (exec_snapshot + UPD_BURSTS + INIT_BURSTS));
        for (idx = 0; idx < NUM_CHIPS; idx = idx + 1) begin
            `REQUIRE(chip_dac[idx] === 48'h000000000000);
        end

        // ---- in_signed is latched with the sample, not read later ----
        in_signed = {N{1'b0}};
        for (idx = 0; idx < N; idx = idx + 1) words[(W*idx) + (W-1) -: W] = {W{1'b0}};
        @(negedge clk);
        guard = 0;
        while (!in_ready) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        in_words = words;
        in_valid = 1'b1;
        @(negedge clk);
        in_valid  = 1'b0;
        in_signed = {N{1'b1}};          // Flipped right after acceptance; this sample must not see it
        guard     = 0;
        while (!in_ready) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        for (idx = 0; idx < N; idx = idx + 1) begin
            // Accepted while unsigned, so zero must still mean zero scale rather than mid scale.
            `REQUIRE(chip_dac[idx / 4][12*(idx % 4) +: 12] === 12'h000);
        end
        in_signed = SIGNED_MASK[N-1:0];
        @(negedge clk);

        // ---- cfg_ref is captured when cfg_apply is raised, not when the request is finally served ----
        guard = 0;
        while (!in_ready) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        in_words = {(W*N){1'b1}};
        in_valid = 1'b1;
        @(negedge clk);
        in_valid = 1'b0;                // The engine is now busy with an update
        repeat (4) @(negedge clk);
        cfg_ref = 2'b11;
        @(negedge clk);
        cfg_apply = 1'b1;
        @(negedge clk);
        cfg_apply = 1'b0;
        cfg_ref   = 2'b00;              // The caller moves on before the request can be served
        guard     = 0;
        while (!in_ready) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        check_init(2'b11);              // The REF frame must carry the mode requested, not the current one
        cfg_ref = 2'b01;
        @(negedge clk);

        // ---- A second request must survive landing on the cycle the first one is served ----
        // That coincidence is one cycle wide and there is no observable marker for it, so bracket the end of an
        // update and sweep. Only one harness does this, since the logic does not depend on the parameters.
        if (SWEEP_CFG != 0) begin
            for (rr = UPD_CYCLES - 60; rr < (UPD_CYCLES + 60); rr = rr + 1) begin
                guard = 0;
                while (!in_ready) begin
                    @(negedge clk);
                    guard = guard + 1;
                    `REQUIRE(guard < 200000);
                end
                in_words = {(W*N){1'b1}};
                in_valid = 1'b1;
                @(negedge clk);
                in_valid = 1'b0;
                cfg_ref  = 2'b10;
                @(negedge clk);
                cfg_apply = 1'b1;
                @(negedge clk);
                cfg_apply = 1'b0;                       // First request, mode 2
                repeat (rr) @(negedge clk);
                cfg_ref = 2'b11;
                @(negedge clk);
                cfg_apply = 1'b1;
                @(negedge clk);
                cfg_apply = 1'b0;                       // Second request, mode 3
                guard = 0;
                while (!in_ready) begin
                    @(negedge clk);
                    guard = guard + 1;
                    `REQUIRE(guard < 200000);
                end
                // Whatever the phase, the reference finally programmed is the one last asked for.
                `REQUIRE(chip_ref[0] === 2'b11);
            end
            cfg_ref = 2'b01;
            @(negedge clk);
        end

        // ---- A reset in the middle must re-run the configuration and clear the outputs ----
        reset_with(2'b10);
        check_init(2'b10);
        for (idx = 0; idx < NUM_CHIPS; idx = idx + 1) `REQUIRE(chip_dac[idx] === 48'h000000000000);

        $display("max5715_harness %0d: passed (W=%0d N=%0d SCLK_DIV=%0d chips=%0d)",
                 ID, W, N, SCLK_DIV, NUM_CHIPS);
        done = 1'b1;
    end
endmodule

// ======================================================================================================== TOP

module max5715_tb;
    // 100 MHz, the clock the driver is intended to run at on the Arty S7.
    reg clk = 0;
    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    wire [7:0] done;

    // The target operating point: io_sclk = clk/2 = 50 MHz, the rated maximum of the part.
    max5715_harness#(.ID(1), .SWEEP_CFG(1), .SIGNED_MASK(4'b1010), .W(12), .N(4), .SCLK_DIV(2))
        h_target (.clk(clk), .done(done[0]));

    // Wider input words, unsigned coding, and a larger divisor.
    max5715_harness#(.ID(2), .SIGNED_MASK(4'b0110), .W(16), .N(4), .SCLK_DIV(4)) h_wide (.clk(clk), .done(done[1]));

    // Two chips daisy-chained; 16.7 MHz stays under the 20 MHz the data sheet allows for a chain.
    max5715_harness#(.ID(3), .SIGNED_MASK(8'b11001001), .W(12), .N(8), .SCLK_DIV(6))
        h_chain (.clk(clk), .done(done[2]));

    // A chain whose last chip is only partly used, which must leave its other channels alone.
    max5715_harness#(.ID(4), .SIGNED_MASK(5'b10101), .W(12), .N(5), .SCLK_DIV(6)) h_partial (.clk(clk), .done(done[3]));

    // Degenerate single-channel instance with a large divisor.
    max5715_harness#(.ID(5), .SIGNED_MASK(0), .W(12), .N(1), .SCLK_DIV(8)) h_one (.clk(clk), .done(done[4]));

    // Leaves STARTUP_CYCLES at its derived default, so the real 400 us power-up hold-off is exercised too.
    max5715_harness#(.ID(6), .SIGNED_MASK(4'b0101), .W(12), .N(4), .SCLK_DIV(2),
                     .STARTUP_CYCLES((100_000_000 + 2499) / 2500)) h_startup (.clk(clk), .done(done[5]));

    // 200 MHz, where one clk cycle is 5 ns: any runt io_sclk pulse breaks tCH and tSCLK outright.
    reg clk_fast = 0;
    /* verilator lint_off BLKSEQ */
    always #2.5 clk_fast = ~clk_fast;
    /* verilator lint_on BLKSEQ */

    max5715_harness#(.ID(7), .SIGNED_MASK(4'b1111), .W(12), .N(4), .CLK_HZ(200_000_000), .SCLK_DIV(4))
        h_fast (.clk(clk_fast), .done(done[6]));

    // A word narrower than the code field, which must be zero-filled at the bottom rather than rejected.
    max5715_harness#(.ID(8), .SIGNED_MASK(4'b1100), .W(8), .N(4), .SCLK_DIV(4))
        h_narrow (.clk(clk), .done(done[7]));

    initial begin
        $dumpfile("max5715_tb.vcd");
        $dumpvars();
        wait (done == 8'b11111111);
        $display("max5715_tb: all checks passed");
        $finish;
    end
endmodule

`default_nettype wire
