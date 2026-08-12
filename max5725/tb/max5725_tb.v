// Testbench for max5725. Run via `fusesoc run --target=sim zubax:kulibin:max5725`, or under Verilator via
// `make verilate` from the repository root.
//
// The bench models a MAX5725 at register level and doubles as a protocol and timing checker: it decodes every
// frame, applies it, and fails on any data sheet timing violation measured at its own pins. Several harnesses
// instantiate the driver with different parameters. LDAC and CLR are taken as strapped inactive -- the
// driver's board contract -- so the model carries only the three pins the driver drives. The analog transfer
// function is checked against the real part instead; see ../tools/hw_test.py.

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

// ================================================================================================= DAC MODEL

// Register-level model of one MAX5725 with the SPI timing checks. Blocking assignments are used throughout
// because the decode has to be sequential; that is normal for a behavioural model but Verilator flags it.
/* verilator lint_off BLKSEQ */
module max5725_model#(
    parameter ID = 0,               // Reported in diagnostics
    parameter MZ = 0,               // State of the device's M/Z pin: 0 zero scale, 1 mid scale
    // Power-up calibration, during which every command is ignored (Note 9), so one arriving inside it is a
    // driver defect. Measured on a MAX5725AWP+, only power-up arms this: frames 130 ns after a SW_RESET
    // execute normally.
    parameter real CAL_NS = 0.0,
    // SPI timing limits from the MAX5723/MAX5724/MAX5725 data sheet, in nanoseconds, for VDDIO >= 2.7 V.
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

    // Observable state, packed because Verilog-2001 has no unpacked array ports.
    output wire [95:0]  dac_flat,   // DAC registers, channel 0 in the low bits, 12 bits each
    output wire [95:0]  code_flat,  // CODE registers
    output wire [383:0] log_flat,   // The last 16 executed frames, index 0 = most recent
    output wire [15:0]  exec_cnt,   // Number of frames executed since time zero
    output wire [1:0]   ref_mode,
    output wire         ref_pwr,
    output wire [15:0]  pwr_flat,   // Power mode, 2 bits per channel
    output wire [39:0]  cfg_flat,   // {WC[1:0], GTB, LDB, CLB} per channel
    output wire [15:0]  wdog_cfg,   // WDOG register as written; must stay at its disabled default
    output wire         gated,      // A SW_GATE_SET is outstanding
    output wire [7:0]   pwr_written // Channels a POWER command has selected since the last reset
);
    localparam LOG_DEPTH = 16;
    localparam [11:0] MZ_CODE = (MZ != 0) ? 12'h800 : 12'h000;

    reg [11:0] code_m [0:7];
    reg [11:0] dac_m  [0:7];
    reg [11:0] ret_m  [0:7];        // RETURN registers
    reg [2:0]  dflt_m [0:7];        // DEFAULT selection
    reg [1:0]  pwr_m  [0:7];
    reg [4:0]  cfg_m  [0:7];        // {WC[1:0], GTB, LDB, CLB}
    reg        dirty_m [0:7];       // CODE written since the last load; LOADn skips channels without it
    reg [23:0] log_m  [0:LOG_DEPTH-1];
    reg [1:0]  ref_mode_m;
    reg        ref_pwr_m;
    reg [15:0] wdog_m;              // Timeout selection, mask and safety level, as written
    reg        gated_m;
    reg [7:0]  pwr_written_m;   // POWER leaves the registers at their reset value, so track that it landed
    reg [15:0] n_exec;

    reg [22:0] shreg;               // The 24th bit is consumed as it arrives, so only 23 need storing
    integer    edges;               // Falling edges seen so far in the current CSB-low window
    integer    executed;            // Frames executed in the current window; must end up exactly 1

    real t_din;                     // Time of the last din transition
    real t_fall;                    // Time of the last sclk falling edge
    real t_rise;                    // Time of the last sclk rising edge
    real t_csb_fall;
    real t_csb_rise;
    real t_win_last_fall;           // Last falling edge of the previous window, for tCSF
    real t_ready;                   // Nothing is accepted until this time; see CAL_NS
    reg  armed;                     // Suppresses checks until the first frame starts

    integer i;

    assign exec_cnt = n_exec;
    assign ref_mode = ref_mode_m;
    assign ref_pwr  = ref_pwr_m;
    assign wdog_cfg = wdog_m;
    assign gated    = gated_m;
    assign pwr_written = pwr_written_m;

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_state
            assign dac_flat[12*gi +: 12]  = dac_m[gi];
            assign code_flat[12*gi +: 12] = code_m[gi];
            assign pwr_flat[2*gi +: 2]    = pwr_m[gi];
            assign cfg_flat[5*gi +: 5]    = cfg_m[gi];
        end
        for (gi = 0; gi < LOG_DEPTH; gi = gi + 1) begin : g_log
            assign log_flat[24*gi +: 24] = log_m[gi];
        end
    endgenerate

    task automatic reset_state;
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                code_m[k]  = MZ_CODE;       // Power-on reset and SW_RESET both land on the M/Z default
                dac_m[k]   = MZ_CODE;
                ret_m[k]   = 12'h000;
                dflt_m[k]  = 3'b000;
                pwr_m[k]   = 2'b00;
                cfg_m[k]   = 5'b00000;
                dirty_m[k] = 1'b0;
            end
            ref_mode_m = 2'b00;             // Power-on default is the external reference, powered down
            ref_pwr_m  = 1'b0;
            wdog_m     = 16'h0000;
            gated_m    = 1'b0;
            pwr_written_m = 8'h00;
        end
    endtask

    initial begin
        reset_state();
        shreg      = 23'h000000;
        edges      = 0;
        executed   = 0;
        n_exec     = 16'd0;
        t_din      = 0.0;
        t_fall     = 0.0;
        t_rise     = 0.0;
        t_csb_fall = 0.0;
        t_csb_rise = 0.0;
        t_win_last_fall = 0.0;
        t_ready    = CAL_NS;        // The part calibrates after power-up before it will listen
        armed      = 1'b0;
        for (i = 0; i < LOG_DEPTH; i = i + 1) log_m[i] = 24'h000000;
    end

    // The value a channel falls back to on a clear or gate, per its DEFAULT setting.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [11:0] default_code;
        input integer k;
        begin
            case (dflt_m[k])
                3'b000:  default_code = MZ_CODE;
                3'b001:  default_code = 12'h000;
                3'b010:  default_code = 12'h800;
                3'b011:  default_code = 12'hFFF;
                3'b100:  default_code = ret_m[k];
                default: default_code = dac_m[k];   // 101..111 leave the behaviour unchanged
            endcase
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    task automatic bad;
        input [8*32-1:0] why;
        input [23:0]     f;
        begin
            $display("model %0d: %0s command %06h at %0t", ID, why, f, $realtime);
            $fatal;
        end
    endtask

    // Applies one 24-bit SPI operation. $fatal on anything the data sheet marks reserved, so that a driver
    // emitting a malformed command cannot pass silently.
    task automatic execute;
        input [23:0] f;
        reg [11:0] c;
        reg [7:0]  sel;             // Per-channel selection mask
        integer k;
        begin
            if ($realtime < t_ready) begin
                $display("model %0d: command %06h at %0t lands inside the calibration window ending %0.1f ns",
                         ID, f, $realtime, t_ready);
                $fatal;
            end
            c = f[15:4];            // Codes are left justified into B[15:4]
            // Table 3: B19 set selects every DAC, otherwise B[18:16] is the channel number.
            if (f[19]) sel = 8'hFF;
            else       sel = 8'h01 << f[18:16];

            case (f[23:20])
                4'b0001: begin                                      // WDOG
                    wdog_m = {f[15:4], f[3:0]};
                end
                4'b0010: begin                                      // REF
                    if (f[19] !== 1'b0) bad("reserved bit set in", f);
                    ref_pwr_m  = f[18];
                    ref_mode_m = f[17:16];
                end
                4'b0011: begin                                      // Keyed software commands
                    if (f[15:0] !== 16'h9630) bad("wrong key in", f);
                    case (f[19:16])
                        4'b0000: gated_m = 1'b0;                    // SW_GATE_CLR
                        4'b0001: gated_m = 1'b1;                    // SW_GATE_SET
                        4'b0010: begin end                          // WD_REFRESH
                        4'b0011: begin end                          // WD_RESET
                        4'b0100: begin                              // SW_CLEAR
                            for (k = 0; k < 8; k = k + 1) if (!cfg_m[k][0]) begin
                                code_m[k]  = default_code(k);
                                dac_m[k]   = code_m[k];
                                dirty_m[k] = 1'b0;
                            end
                        end
                        4'b0101: reset_state();                     // SW_RESET
                        default: bad("reserved", f);
                    endcase
                end
                4'b0100: begin                                      // POWER
                    if (f[19:16] !== 4'b0000) bad("reserved bit set in", f);
                    for (k = 0; k < 8; k = k + 1) if (f[8+k]) begin
                        pwr_m[k] = f[7:6];
                        pwr_written_m[k] = 1'b1;
                    end
                end
                4'b0101: begin                                      // CONFIG
                    if (f[19:16] !== 4'b0000) bad("reserved bit set in", f);
                    for (k = 0; k < 8; k = k + 1) if (f[8+k]) cfg_m[k] = f[7:3];
                end
                4'b0110: begin                                      // DEFAULT
                    if (f[19:16] !== 4'b0000) bad("reserved bit set in", f);
                    for (k = 0; k < 8; k = k + 1) if (f[8+k]) dflt_m[k] = f[7:5];
                end
                4'b0111: begin                                      // RETURNn
                    for (k = 0; k < 8; k = k + 1) if (sel[k]) ret_m[k] = c;
                end
                4'b1000: begin                                      // CODEn
                    for (k = 0; k < 8; k = k + 1) if (sel[k]) begin
                        code_m[k]  = c;
                        dirty_m[k] = 1'b1;
                    end
                end
                4'b1001: begin                                      // LOADn
                    for (k = 0; k < 8; k = k + 1) if (sel[k] && dirty_m[k]) begin
                        dac_m[k]   = code_m[k];
                        dirty_m[k] = 1'b0;
                    end
                end
                4'b1010: begin                                      // CODEn_LOAD_ALL
                    for (k = 0; k < 8; k = k + 1) if (sel[k]) begin
                        code_m[k]  = c;
                        dirty_m[k] = 1'b1;
                    end
                    for (k = 0; k < 8; k = k + 1) if (dirty_m[k]) begin
                        dac_m[k]   = code_m[k];
                        dirty_m[k] = 1'b0;
                    end
                end
                4'b1011: begin                                      // CODEn_LOADn
                    for (k = 0; k < 8; k = k + 1) if (sel[k]) begin
                        code_m[k]  = c;
                        dac_m[k]   = c;
                        dirty_m[k] = 1'b0;
                    end
                end
                4'b1100: begin
                    case (f[19:16])
                        4'b0000: begin                              // CODE_ALL
                            for (k = 0; k < 8; k = k + 1) begin
                                code_m[k]  = c;
                                dirty_m[k] = 1'b1;
                            end
                        end
                        4'b0001: begin                              // LOAD_ALL
                            for (k = 0; k < 8; k = k + 1) begin
                                dac_m[k]   = code_m[k];
                                dirty_m[k] = 1'b0;
                            end
                        end
                        4'b0010: begin                              // CODE_ALL_LOAD_ALL
                            for (k = 0; k < 8; k = k + 1) begin
                                code_m[k]  = c;
                                dac_m[k]   = c;
                                dirty_m[k] = 1'b0;
                            end
                        end
                        4'b0011: begin                              // RETURN_ALL
                            for (k = 0; k < 8; k = k + 1) ret_m[k] = c;
                        end
                        // 1100_01xx and 1100_1xxx are the documented no-operation space.
                        default: begin end
                    endcase
                end
                4'b1101: begin end                                  // SPI_DATA_REQUEST; DOUT is not modelled
                4'b1110: begin end                                  // SPI_READ_STATUS / SPI_READ_DATA
                default: bad("reserved", f);                        // 0000 and 1111
            endcase

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
            // Fewer than 24 clocks is not a fault -- such an operation is simply not executed, which is what
            // makes a reset in mid-frame safe. More than 24 would mean the driver overran a frame.
            `REQUIRE(edges <= 24);
            `REQUIRE(executed === ((edges === 24) ? 1 : 0));
            if (($realtime - t_fall) < T_CSH1_MIN) fail("tCSH1", $realtime - t_fall, T_CSH1_MIN);
            t_win_last_fall = t_fall;
        end
        t_csb_rise = $realtime;
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
            t_fall = $realtime;
            if (edges == 23) execute({shreg, din});
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

// One driver instance, the behavioural chip, the stimulus and the checks. Asserts `done` when finished.
module max5725_harness#(
    parameter ID          = 0,
    parameter SWEEP_CFG   = 0,      // Sweep the cfg_apply/service coincidence; slow, so one harness does it
    parameter SIGNED_MASK = 0,      // Initial value driven on in_signed; varied at runtime by the stimulus
    parameter MZ          = 0,      // Modelled state of the device's M/Z pin
    parameter W        = 12,
    parameter N        = 8,
    parameter CLK_HZ   = 100_000_000,
    parameter SCLK_DIV = 2,
    // Deliberately not a round number, so an off-by-one cannot hide. It also has to exceed one gap plus one
    // frame at the slowest divisor, or the modelled calibration window would be shorter than the frame that
    // follows SW_RESET and could never catch a driver that fails to wait it out.
    parameter DEFAULT_STARTUP = 0,  // Let the driver use its own STARTUP_CYCLES; must match the value below
    parameter STARTUP_CYCLES = 331
)(
    input  wire clk,
    output reg  done
);
    localparam CODE_BURSTS = N;
    localparam UPD_BURSTS  = CODE_BURSTS + 1;
    localparam INIT_BURSTS = 4;
    // Roughly how long an update occupies the engine, used to bracket the cfg_apply coincidence sweep.
    localparam GAP_C      = ((CLK_HZ + 9_999_999) / 10_000_000) + 2;
    localparam UPD_CYCLES = UPD_BURSTS * ((SCLK_DIV * 25) + GAP_C + 2);
    // The driver aligns each word to the top of the code field, zero-filling or truncating the low bits.
    localparam TAKE = (W < 12) ? W : 12;
    localparam [11:0] FILL_SCALE = 12'd1 << (12 - TAKE);

    localparam [23:0] FRM_SW_RESET = 24'h35_9630;
    localparam [23:0] FRM_POWER    = 24'h40_FF00;
    localparam [23:0] FRM_CONFIG   = 24'h50_FF28;
    localparam [23:0] FRM_LOAD_ALL = 24'hC1_0000;

    // Where every DAC register sits after a power-on reset or a SW_RESET, which the device derives from M/Z.
    localparam [11:0] MZ_CODE = (MZ != 0) ? 12'h800 : 12'h000;
    localparam [95:0] DAC_DEFAULT = {8{MZ_CODE}};

    // The device's calibration window, as the model should enforce it. Set just short of what the driver
    // waits, so a driver that honours the window passes and one that does not is caught on the first frame
    // after SW_RESET rather than silently losing the rest of its configuration.
    localparam real CLK_PERIOD_NS = 1000000000.0 / CLK_HZ;
    localparam real MODEL_CAL_NS  = STARTUP_CYCLES * CLK_PERIOD_NS * 0.98;

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

    // With DEFAULT_STARTUP the driver keeps its own STARTUP_CYCLES, so the derived default is what the checks
    // measure. Passing a copy of the same expression would agree with any default, however wrong.
    generate
        if (DEFAULT_STARTUP != 0) begin : g_dut_default
            max5725#(
                .W(W), .N(N), .CLK_HZ(CLK_HZ), .SCLK_DIV(SCLK_DIV)
            ) dut (
                .clk(clk), .rst(rst), .cfg_ref(cfg_ref), .cfg_apply(cfg_apply),
                .in_valid(in_valid), .in_ready(in_ready), .in_words(in_words), .in_signed(in_signed),
                .io_sclk(io_sclk), .io_cs_n(io_cs_n), .io_mosi(io_mosi)
            );
        end else begin : g_dut
            max5725#(
                .W(W), .N(N), .CLK_HZ(CLK_HZ), .SCLK_DIV(SCLK_DIV), .STARTUP_CYCLES(STARTUP_CYCLES)
            ) dut (
                .clk(clk), .rst(rst), .cfg_ref(cfg_ref), .cfg_apply(cfg_apply),
                .in_valid(in_valid), .in_ready(in_ready), .in_words(in_words), .in_signed(in_signed),
                .io_sclk(io_sclk), .io_cs_n(io_cs_n), .io_mosi(io_mosi)
            );
        end
    endgenerate

    wire [95:0]  m_dac;
    wire [95:0]  m_code;
    wire [383:0] m_log;
    wire [15:0]  m_exec;
    wire [1:0]   m_ref;
    wire         m_rpwr;
    wire [15:0]  m_pwr;
    wire [39:0]  m_cfg;
    wire [15:0]  m_wdog;
    wire         m_gated;
    wire [7:0]   m_pwr_written;

    max5725_model#(.ID(ID), .MZ(MZ), .CAL_NS(MODEL_CAL_NS)) m (
        .csb(io_cs_n), .sclk(io_sclk), .din(io_mosi),
        .dac_flat(m_dac), .code_flat(m_code), .log_flat(m_log), .exec_cnt(m_exec),
        .ref_mode(m_ref), .ref_pwr(m_rpwr), .pwr_flat(m_pwr), .cfg_flat(m_cfg),
        .wdog_cfg(m_wdog), .gated(m_gated), .pwr_written(m_pwr_written)
    );

    // The serial clock must never move while the chip select is deasserted.
    reg quiet_armed;
    initial quiet_armed = 1'b0;
    // Not while rst is asserted: parking the pins is exactly when these two are expected to move together.
    // The point here is that the clock stays quiet between frames, where it would couple into the outputs.
    always @(io_sclk) begin
        if (quiet_armed && !rst && (io_cs_n !== 1'b0)) begin
            $display("harness %0d: io_sclk moved while io_cs_n deasserted at %0t", ID, $realtime);
            $fatal;
        end
    end

    // Every io_sclk high phase must last exactly half an io_sclk period. The model's tCH check is in absolute
    // time and so cannot see a runt pulse while a clk cycle still exceeds 8 ns; this can, at any clock rate.
    integer sclk_hi;
    initial sclk_hi = 0;
    // Reset legitimately truncates the pulse in flight, since its frame is aborted. This monitor is about the
    // steady-state width, so clear the count rather than complain about the stub.
    always @(posedge clk) begin
        if (rst) begin
            sclk_hi <= 0;
        end else if (io_sclk) begin
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
    reg [95:0] dac_before;
    reg [95:0] dac_expect;
    reg        atomic_armed;
    initial atomic_armed = 1'b0;
    always @(m_dac) begin
        if (atomic_armed && (m_dac !== dac_before) && (m_dac !== dac_expect)) begin
            $display("harness %0d: partial DAC update %024h at %0t (before %024h, expect %024h)",
                     ID, m_dac, $realtime, dac_before, dac_expect);
            $fatal;
        end
    end

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

    // The CODEn frame the driver is expected to emit for a channel.
    function automatic [23:0] want_codn;
        input [2:0]  ch;
        input [11:0] code;
        begin
            want_codn = {5'b10000, ch, code, 4'h0};
        end
    endfunction

    integer guard;

    // Waits until the driver is ready to take a sample, refusing to hang for ever if it never is.
    task automatic wait_ready;
        begin
            guard = 0;
            while (!in_ready) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 200000);
            end
        end
    endtask

    // Drives one reset pulse with the given reference selection and waits for the configuration to complete.
    task automatic reset_with;
        input [1:0] refsel;
        reg [15:0] exec_at_reset;
        begin
            atomic_armed  = 1'b0;
            exec_at_reset = m_exec;             // The model counts frames since time zero, never resetting
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
            `REQUIRE(m_exec === exec_at_reset);
            wait_ready();
            // in_ready may not rise before the whole configuration sequence has actually been executed.
            `REQUIRE(m_exec >= (exec_at_reset + 16'd4));
        end
    endtask

    // Presents one sample and waits until the driver is idle again.
    task automatic send;
        input [(W*N)-1:0] words;
        begin
            @(negedge clk);
            wait_ready();
            in_words = words;
            in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            `REQUIRE(!in_ready);                    // The accept must have been taken on the intervening posedge
            wait_ready();
        end
    endtask

    // Snapshots the current DAC state and computes what it must become, arming the atomicity monitor.
    task automatic arm_expect;
        input [(W*N)-1:0] words;
        integer k;
        begin
            dac_before = m_dac;
            dac_expect = m_dac;
            for (k = 0; k < N; k = k + 1) begin
                dac_expect[12*k +: 12] = want_code(words[(W*k) + (W-1) -: W], in_signed[k]);
            end
            atomic_armed = 1'b1;
        end
    endtask

    // Sends one sample and verifies every DAC register, plus the exact frame sequence that was used.
    task automatic send_and_check;
        input [(W*N)-1:0] words;
        integer k;
        reg [15:0] exec0;
        begin
            arm_expect(words);
            exec0 = m_exec;
            send(words);
            `REQUIRE(m_dac === dac_expect);
            `REQUIRE(m_code === dac_expect);        // LOAD_ALL copies CODE into DAC, so both agree
            // The update is one CODEn per channel in ascending order, then a single LOAD_ALL.
            `REQUIRE(m_log[24*0 +: 24] === FRM_LOAD_ALL);
            for (k = 0; k < CODE_BURSTS; k = k + 1) begin
                `REQUIRE(m_log[24*(CODE_BURSTS-k) +: 24]
                         === want_codn(k[2:0], want_code(words[(W*k) + (W-1) -: W], in_signed[k])));
            end
            `REQUIRE(m_exec === (exec0 + UPD_BURSTS));
            atomic_armed = 1'b0;
        end
    endtask

    // Verifies the four-frame configuration sequence and the device state it must leave behind.
    task automatic check_init;
        input [1:0] refsel;
        integer k;
        begin
            `REQUIRE(m_exec >= 16'd4);
            `REQUIRE(m_log[24*3 +: 24] === FRM_SW_RESET);
            `REQUIRE(m_log[24*2 +: 24] === FRM_POWER);
            `REQUIRE(m_log[24*1 +: 24] === FRM_CONFIG);
            `REQUIRE(m_log[24*0 +: 24] === {6'b001001, refsel, 16'h0000});
            `REQUIRE(m_ref  === refsel);
            `REQUIRE(m_rpwr === 1'b1);              // The reference is asked to stay powered in standby
            // A write-only driver could never feed a watchdog, so it must leave it disabled and ungated.
            `REQUIRE(m_wdog === 16'h0000);
            `REQUIRE(m_gated === 1'b0);
            // PD=00 is also the reset default, so the mode alone would pass a POWER frame selecting nothing.
            `REQUIRE(m_pwr_written === 8'hFF);
            for (k = 0; k < 8; k = k + 1) begin
                `REQUIRE(m_pwr[2*k +: 2] === 2'b00);        // Normal power mode on every channel
                // WC=00 watchdog disabled, GTB=1 gating disabled, LDB=0 latch operational, CLB=1 CLR ignored.
                `REQUIRE(m_cfg[5*k +: 5] === 5'b00101);
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
            exec_snapshot = m_exec;
            repeat (50 * SCLK_DIV) @(negedge clk);
            `REQUIRE(m_exec === exec_snapshot);
            `REQUIRE(in_ready);
        end

        // ---- Zero scale, full scale, mid scale, and a distinct pattern per channel ----
        reset_with(2'b01);
        check_init(2'b01);
        `REQUIRE(m_dac === DAC_DEFAULT);        // SW_RESET lands on the M/Z-selected default

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
        wait_ready();
        in_words = words;
        in_valid = 1'b1;
        @(negedge clk);
        `REQUIRE(!in_ready);
        // Hold in_valid asserted with different data for the whole transaction; it must have no effect.
        in_words = ~words;
        wait_ready();
        in_valid = 1'b0;
        `REQUIRE(m_dac === dac_expect);
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
                `REQUIRE(m_dac[12*idx +: 12] === (in_signed[idx] ? 12'h000 : 12'h800));
            end
            words = {(W*N){1'b0}};
            send_and_check(words);
            for (idx = 0; idx < N; idx = idx + 1) begin
                `REQUIRE(m_dac[12*idx +: 12] === (in_signed[idx] ? 12'h800 : 12'h000));
            end
        end
        in_signed = SIGNED_MASK[N-1:0];
        @(negedge clk);

        // ---- cfg_apply must re-send the configuration without needing a reset ----
        // A single-cycle pulse is enough.
        words = {(W*N){1'b1}};
        send_and_check(words);
        `REQUIRE(m_dac !== DAC_DEFAULT);
        exec_snapshot = m_exec;
        cfg_ref       = 2'b11;
        @(negedge clk);
        cfg_apply = 1'b1;
        @(negedge clk);
        cfg_apply = 1'b0;
        // cfg_apply exists for a DAC whose supply came up after the FPGA's, so its first frame has to wait out
        // the power-up calibration just as the post-reset sequence does. Count the cycles to prove it does.
        guard = 0;
        while (io_cs_n !== 1'b0) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        `REQUIRE(guard >= STARTUP_CYCLES);
        guard = 0;
        while (!in_ready || (m_exec === exec_snapshot)) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        `REQUIRE(m_exec === (exec_snapshot + INIT_BURSTS));
        check_init(2'b11);
        // SW_RESET is part of the sequence, so the outputs return to the device's M/Z-selected default.
        `REQUIRE(m_dac === DAC_DEFAULT);

        // Held high, it must still produce exactly one sequence rather than looping for as long as it is high.
        exec_snapshot = m_exec;
        cfg_ref       = 2'b10;
        @(negedge clk);
        cfg_apply = 1'b1;
        guard     = 0;
        while (!in_ready || (m_exec === exec_snapshot)) begin
            @(negedge clk);
            guard = guard + 1;
            `REQUIRE(guard < 200000);
        end
        `REQUIRE(m_exec === (exec_snapshot + INIT_BURSTS));
        check_init(2'b10);
        exec_snapshot = m_exec;
        repeat (80 * SCLK_DIV) @(negedge clk);       // Still asserted; nothing further may be sent
        `REQUIRE(m_exec === exec_snapshot);
        `REQUIRE(in_ready);
        cfg_apply = 1'b0;
        @(negedge clk);
        cfg_ref = 2'b01;

        // A request that coincides with an accepted sample does not outrank it: the sample was offered while
        // in_ready was high, so the handshake obliges the driver to take it, and the configuration follows.
        // The consequence is that the configuration's SW_RESET then clears what the sample just wrote, which
        // is why cfg_apply belongs in an idle moment.
        exec_snapshot = m_exec;
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
        wait_ready();
        `REQUIRE(m_exec === (exec_snapshot + UPD_BURSTS + INIT_BURSTS));
        `REQUIRE(m_dac === DAC_DEFAULT);

        // ---- in_signed is latched with the sample, not read later ----
        in_signed = {N{1'b0}};
        for (idx = 0; idx < N; idx = idx + 1) words[(W*idx) + (W-1) -: W] = {W{1'b0}};
        @(negedge clk);
        wait_ready();
        in_words = words;
        in_valid = 1'b1;
        @(negedge clk);
        in_valid  = 1'b0;
        in_signed = {N{1'b1}};          // Flipped right after acceptance; this sample must not see it
        wait_ready();
        for (idx = 0; idx < N; idx = idx + 1) begin
            // Accepted while unsigned, so zero must still mean zero scale rather than mid scale.
            `REQUIRE(m_dac[12*idx +: 12] === 12'h000);
        end
        in_signed = SIGNED_MASK[N-1:0];
        @(negedge clk);

        // ---- cfg_ref is captured when cfg_apply is raised, not when the request is finally served ----
        wait_ready();
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
        wait_ready();
        check_init(2'b11);              // The REF frame must carry the mode requested, not the current one
        cfg_ref = 2'b01;
        @(negedge clk);

        // ---- A second request must survive landing on the cycle the first one is served ----
        // That coincidence is one cycle wide and there is no observable marker for it, so bracket the end of an
        // update and sweep. Only one harness does this, since the logic does not depend on the parameters.
        if (SWEEP_CFG != 0) begin
            for (rr = UPD_CYCLES - 60; rr < (UPD_CYCLES + 60); rr = rr + 1) begin
                wait_ready();
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
                wait_ready();
                // Whatever the phase, the reference finally programmed is the one last asked for.
                `REQUIRE(m_ref === 2'b11);
            end
            cfg_ref = 2'b01;
            @(negedge clk);
        end

        // ---- A reset landing inside a frame must abort cleanly and come back with a configuration ----
        // An operation of fewer than 24 clocks is not executed, so an aborted frame is harmless provided the
        // driver parks its pins and reconfigures. Vary where in the frame the reset lands.
        for (rr = 0; rr < 6; rr = rr + 1) begin
            wait_ready();
            in_words = {(W*N){1'b1}};
            in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            repeat ((rr * 7) + 1) @(negedge clk);
            reset_with(2'b01);
            check_init(2'b01);
            `REQUIRE(m_dac === DAC_DEFAULT);
        end

        // ---- A reset while idle must re-run the configuration and restore the default outputs ----
        reset_with(2'b10);
        check_init(2'b10);
        `REQUIRE(m_dac === DAC_DEFAULT);

        $display("max5725_harness %0d: passed (W=%0d N=%0d SCLK_DIV=%0d MZ=%0d)", ID, W, N, SCLK_DIV, MZ);
        done = 1'b1;
    end
endmodule

// ======================================================================================================== TOP

module max5725_tb;
    // 100 MHz, the clock the driver is intended to run at on the Arty S7.
    reg clk = 0;
    /* verilator lint_off BLKSEQ */
    always #5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    wire [7:0] done;

    // The target operating point: all eight channels, io_sclk = clk/2 = 50 MHz, the rated maximum of the part.
    // M/Z is modelled high, matching the bench board, whose JU1 shunt ties it to VDDIO.
    max5725_harness#(.ID(1), .SWEEP_CFG(1), .SIGNED_MASK(8'b10100110), .MZ(1), .W(12), .N(8), .SCLK_DIV(2))
        h_target (.clk(clk), .done(done[0]));

    // Wider input words, whose surplus low bits must be discarded, and a larger divisor.
    max5725_harness#(.ID(2), .SIGNED_MASK(8'b01101001), .W(16), .N(8), .SCLK_DIV(4))
        h_wide (.clk(clk), .done(done[1]));

    // Fewer channels than the device has: the unused ones must be left at their power-on default.
    max5725_harness#(.ID(3), .SIGNED_MASK(4'b1010), .MZ(1), .W(12), .N(4), .SCLK_DIV(6))
        h_partial (.clk(clk), .done(done[2]));

    // Degenerate single-channel instance with a large divisor.
    max5725_harness#(.ID(4), .SIGNED_MASK(0), .W(12), .N(1), .SCLK_DIV(8)) h_one (.clk(clk), .done(done[3]));

    // Instantiates the driver without overriding STARTUP_CYCLES, so the derived default -- the real 400 us
    // power-up hold-off -- is the thing under test rather than a copy of its formula.
    max5725_harness#(.ID(5), .SIGNED_MASK(8'b01010101), .W(12), .N(8), .SCLK_DIV(2), .DEFAULT_STARTUP(1),
                     .STARTUP_CYCLES((100_000_000 + 2499) / 2500)) h_startup (.clk(clk), .done(done[4]));

    // A word narrower than the code field, which must be zero-filled at the bottom rather than rejected.
    max5725_harness#(.ID(6), .SIGNED_MASK(5'b11001), .W(8), .N(5), .SCLK_DIV(4))
        h_narrow (.clk(clk), .done(done[5]));

    // One bit per channel: the extreme of the zero-fill path.
    max5725_harness#(.ID(7), .SIGNED_MASK(3'b101), .MZ(1), .W(1), .N(3), .SCLK_DIV(4))
        h_bit (.clk(clk), .done(done[6]));

    // 200 MHz, where one clk cycle is 5 ns: any runt io_sclk pulse breaks tCH and tSCLK outright.
    reg clk_fast = 0;
    /* verilator lint_off BLKSEQ */
    always #2.5 clk_fast = ~clk_fast;
    /* verilator lint_on BLKSEQ */

    max5725_harness#(.ID(8), .SIGNED_MASK(8'b11111111), .W(12), .N(8), .CLK_HZ(200_000_000), .SCLK_DIV(4))
        h_fast (.clk(clk_fast), .done(done[7]));

    initial begin
        $dumpfile("max5725_tb.vcd");
        $dumpvars();
        wait (done == 8'b11111111);
        $display("max5725_tb: all checks passed");
        $finish;
    end
endmodule

`default_nettype wire
