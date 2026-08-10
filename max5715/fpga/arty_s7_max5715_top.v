// Bench harness top level: drives a MAX5715BOB on Pmod JA of a Digilent Arty S7-25 and lets the host set the
// DAC codes over the board's USB-UART, so a measured voltage can be attributed to an exact commanded code.
// This is test scaffolding for max5715, not a reusable library module.
//
// The 12 MHz board oscillator is multiplied to 100 MHz, and SCLK_DIV = 2 puts io_sclk at 50 MHz, the rated
// maximum of the DAC. io_sclk is an ordinary registered output rather than a forwarded clock, so all three
// DAC signals leave the same flip-flop stage in the same I/O bank and their clock-to-out delays track.
//
// Host protocol, little more than a framed register write with an acknowledgement:
//   A5 c0h c0l c1h c1l c2h c2l c3h c3l xor   set the four DAC codes (12 significant bits each), then update
//   B4 ref xor                               re-run configuration (SW_RESET zeroes every output)
//   C3 mask xor                              set the per-channel signed mask, one bit per channel
//   52                                       status: frames the device executed, then a flags byte
//   3F                                       ping
// The trailing xor byte is the exclusive-or of every preceding byte of the frame, so a whole frame including
// its checksum exclusive-ors to zero. Replies are 5A when a command was carried out, EE when it was rejected
// (bad checksum, or an update requested while one is still in flight), and A7 for a ping. The 5A for a code
// update is deliberately sent only once the driver has accepted the sample, so a host that sees an
// acknowledgement knows the transfer is genuinely on the wire.

`default_nettype none

module arty_s7_max5715_top#(
    parameter SCLK_DIV = 2      // Overridable with synth_design -generic so the bench can sweep the rate
)(
    input  wire clk12mhz,       // F14, the 12 MHz board oscillator
    input  wire btn0,           // Manual reset
    input  wire uart_txd_in,    // Host to FPGA, named from the USB bridge's point of view
    output wire uart_rxd_out,   // FPGA to host
    output wire dac_cs_n,       // Pmod JA pin 1  -> MAX5715 CSB, active low
    output wire dac_din,        // Pmod JA pin 2  -> MAX5715 DIN
    output wire dac_sclk,       // Pmod JA pin 4  -> MAX5715 SCLK
    input  wire dac_rdy,        // Pmod JA pin 3  <- MAX5715 RDY, an execution telltale for diagnostics
    output wire dac_clr_n,      // Pmod JA pin 9  -> MAX5715 CLR, held inactive
    output wire dac_ldac_n,     // Pmod JA pin 7  -> MAX5715 LDAC, held inactive
    output wire [3:0] led
);
    localparam CLK_HZ         = 100_000_000;
    localparam UART_BAUD      = 115_200;
    localparam CYCLES_PER_BIT = (CLK_HZ + (UART_BAUD / 2)) / UART_BAUD;
    localparam CHANNELS       = 4;
    localparam CODE_W         = 12;
    localparam SET_PAYLOAD    = 2 * CHANNELS;   // Two bytes per channel, big endian

    generate
        if (CYCLES_PER_BIT < 8) begin : g_chk_baud  arty_s7_max5715_error_baud_too_fast e();  end
    endgenerate

    // Both are active-low DAC inputs that the breakout pulls up through 3 kohm. Relying on that pull-up alone
    // is not safe: an FPGA leaves unused pins with an internal pull of its own, and a pull-down of a few tens
    // of kilohms divides 3.3 V down towards the 0.7*VDDIO input threshold. CLR held low aborts every SPI
    // command in progress, which looks exactly like a dead interface. Drive them instead of hoping.
    assign dac_clr_n  = 1'b1;
    assign dac_ldac_n = 1'b1;

    // ------------------------------------------------ Clocking ------------------------------------------------

    wire clk;
    wire mmcm_fb;
    wire mmcm_fb_buf;
    wire clk_unbuf;
    wire locked;

    // 12 MHz * 50 = 600 MHz VCO, within the Spartan-7 -1 range, divided by 6 for 100 MHz.
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(50.0),
        .CLKIN1_PERIOD(83.333),
        .CLKOUT0_DIVIDE_F(6.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .DIVCLK_DIVIDE(1),
        .STARTUP_WAIT("FALSE")
    ) mmcm (
        .CLKIN1(clk12mhz),
        .CLKFBIN(mmcm_fb_buf),
        .CLKFBOUT(mmcm_fb),
        .CLKOUT0(clk_unbuf),
        .LOCKED(locked),
        .PWRDWN(1'b0),
        .RST(1'b0)
    );
    BUFG bufg_fb  (.I(mmcm_fb),   .O(mmcm_fb_buf));
    BUFG bufg_clk (.I(clk_unbuf), .O(clk));

    // ------------------------------------------------- Reset --------------------------------------------------

    (* ASYNC_REG = "TRUE" *) reg [1:0] lock_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn_sync  = 2'b00;
    reg [7:0] por = 8'hFF;

    always @(posedge clk) begin
        lock_sync <= {lock_sync[0], locked};
        btn_sync  <= {btn_sync[0],  btn0};
        if (!lock_sync[1] || btn_sync[1]) por <= 8'hFF;
        else if (por != 8'h00)            por <= por - 8'h01;
    end

    wire rst_sys = (por != 8'h00);          // Holds the UART, the protocol engine and the driver

    // -------------------------------------------------- DAC ---------------------------------------------------

    reg  [(CODE_W*CHANNELS)-1:0] codes = {(CODE_W*CHANNELS){1'b0}};
    reg  [1:0]                   cfg_ref = 2'b01;    // 2.500 V internal reference by default
    reg                          cfg_apply = 1'b0;   // Pulsed to re-send the configuration to the device
    reg  [CHANNELS-1:0]          in_signed = {CHANNELS{1'b0}};
    reg                          dac_valid = 1'b0;
    wire                         dac_ready;

    // in_signed defaults to all zero so that a commanded value is the DAC code itself, which keeps the measured
    // transfer function free of interpretation; the host can set the mask to exercise the signed path too.
    max5715#(
        .W(CODE_W),
        .N(CHANNELS),
        .CLK_HZ(CLK_HZ),
        .SCLK_DIV(SCLK_DIV)
    ) dac (
        .clk(clk),
        .rst(rst_sys),
        .cfg_ref(cfg_ref),
        .cfg_apply(cfg_apply),
        .in_valid(dac_valid),
        .in_ready(dac_ready),
        .in_words(codes),
        .in_signed(in_signed),
        .io_sclk(dac_sclk),
        .io_cs_n(dac_cs_n),
        .io_mosi(dac_din)
    );

    // -------------------------------------------------- UART --------------------------------------------------

    wire [7:0] rx_data;
    wire       rx_valid;
    reg  [7:0] tx_data = 8'h00;
    reg        tx_valid = 1'b0;
    wire       tx_busy;

    uart_rx#(.CYCLES_PER_BIT(CYCLES_PER_BIT)) urx (
        .clk(clk), .rst(rst_sys), .rx(uart_txd_in), .data(rx_data), .valid(rx_valid)
    );
    uart_tx#(.CYCLES_PER_BIT(CYCLES_PER_BIT)) utx (
        .clk(clk), .rst(rst_sys), .data(tx_data), .valid(tx_valid), .tx(uart_rxd_out), .busy(tx_busy)
    );

    // --------------------------------------- Execution telltale (RDY) ------------------------------------------

    (* ASYNC_REG = "TRUE" *) reg [2:0] rdy_sync = 3'b111;
    reg [15:0] rdy_falls = 16'd0;
    always @(posedge clk) begin
        rdy_sync <= {rdy_sync[1:0], dac_rdy};
        if (rst_sys) rdy_falls <= 16'd0;
        else if (rdy_sync[2] && !rdy_sync[1]) rdy_falls <= rdy_falls + 16'd1;
    end

    // ------------------------------------------------ Protocol ------------------------------------------------

    localparam [7:0] CMD_SET  = 8'hA5;
    localparam [7:0] CMD_REF  = 8'hB4;
    localparam [7:0] CMD_PING = 8'h3F;
    localparam [7:0] CMD_STAT = 8'h52;
    localparam [7:0] CMD_SGN  = 8'hC3;
    localparam [7:0] RSP_ACK  = 8'h5A;
    localparam [7:0] RSP_NAK  = 8'hEE;
    localparam [7:0] RSP_PONG = 8'hA7;

    localparam ST_SYNC = 2'd0;
    localparam ST_SET  = 2'd1;
    localparam ST_REF  = 2'd2;
    localparam ST_SGN  = 2'd3;

    reg [1:0]                 st = ST_SYNC;
    reg [3:0]                 nrx = 4'd0;                       // Payload bytes taken so far in this frame
    reg [7:0]                 csum = 8'h00;                     // Running exclusive-or over the frame
    reg [(8*SET_PAYLOAD)-1:0] shift = {(8*SET_PAYLOAD){1'b0}};  // Payload, oldest byte in the high bits
    reg [15:0]                idle = 16'd0;                     // Abandons a frame if the host goes quiet
    reg                       frame_ok = 1'b0;                  // Last frame outcome, shown on an LED
    reg [7:0]                 rsp = 8'h00;
    reg                       rsp_pending = 1'b0;
    reg [23:0]                rsp_multi = 24'd0;       // Up to three queued reply bytes, first in the high byte
    reg [1:0]                 rsp_multi_n = 2'd0;

    integer ch;

    always @(posedge clk) begin
        tx_valid  <= 1'b0;
        cfg_apply <= 1'b0;                  // One cycle is all the driver needs

        // Reply queue, so a reply is never dropped because the transmitter is still shifting.
        if (!tx_busy && !tx_valid) begin
            if (rsp_multi_n != 2'd0) begin
                tx_data     <= rsp_multi[23:16];
                tx_valid    <= 1'b1;
                rsp_multi   <= {rsp_multi[15:0], 8'h00};
                rsp_multi_n <= rsp_multi_n - 2'd1;
            end else if (rsp_pending) begin
                tx_data     <= rsp;
                tx_valid    <= 1'b1;
                rsp_pending <= 1'b0;
            end
        end

        // Hold the request until the driver takes it; it may still be configuring or mid-transaction.
        if (dac_valid && dac_ready) begin
            dac_valid   <= 1'b0;
            rsp         <= RSP_ACK;
            rsp_pending <= 1'b1;
            frame_ok    <= 1'b1;
        end

        if (rst_sys) begin
            st          <= ST_SYNC;
            nrx         <= 4'd0;
            csum        <= 8'h00;
            idle        <= 16'd0;
            dac_valid   <= 1'b0;
            rsp_pending <= 1'b0;
            rsp_multi_n <= 2'd0;
        end else begin
            if ((st == ST_SYNC) || rx_valid) idle <= 16'd0;
            else if (idle == 16'hFFFF)       st   <= ST_SYNC;    // Drop a truncated frame rather than wedge
            else                             idle <= idle + 16'd1;

            if (rx_valid) begin
                csum  <= csum ^ rx_data;
                shift <= {shift[(8*SET_PAYLOAD)-9:0], rx_data};
                nrx   <= nrx + 4'd1;
                case (st)
                    ST_SYNC: begin
                        csum <= rx_data;
                        nrx  <= 4'd0;
                        case (rx_data)
                            CMD_SET: st <= ST_SET;
                            CMD_REF: st <= ST_REF;
                            CMD_SGN: st <= ST_SGN;
                            CMD_PING: begin
                                rsp         <= RSP_PONG;
                                rsp_pending <= 1'b1;
                            end
                            CMD_STAT: begin
                                // Frames the device has actually executed, plus a flags byte.
                                rsp_multi   <= {rdy_falls, 5'b0, lock_sync[1], dac_ready, frame_ok};
                                rsp_multi_n <= 2'd3;
                            end
                            default: begin end          // Ignore the unrecognised while resynchronising
                        endcase
                    end

                    ST_SET: begin
                        if (nrx == SET_PAYLOAD[3:0]) begin      // This byte is the checksum
                            st <= ST_SYNC;
                            if (((csum ^ rx_data) == 8'h00) && !dac_valid) begin
                                // shift still holds the eight payload bytes: channel ch occupies the 16-bit
                                // field at 8*SET_PAYLOAD-1 - 16*ch downwards, of which the low 12 bits count.
                                for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                                    codes[(CODE_W*ch) +: CODE_W] <=
                                        shift[((8*SET_PAYLOAD) - 5 - (16*ch)) -: CODE_W];
                                end
                                dac_valid <= 1'b1;
                            end else begin
                                rsp         <= RSP_NAK;
                                rsp_pending <= 1'b1;
                                frame_ok    <= 1'b0;
                            end
                        end
                    end

                    ST_REF: begin
                        if (nrx == 4'd1) begin                  // This byte is the checksum
                            st <= ST_SYNC;
                            if ((csum ^ rx_data) == 8'h00) begin
                                cfg_ref     <= shift[1:0];      // shift still holds the reference byte
                                // Re-send the configuration; its SW_RESET zeroes every output.
                                cfg_apply   <= 1'b1;
                                rsp         <= RSP_ACK;
                                rsp_pending <= 1'b1;
                                frame_ok    <= 1'b1;
                            end else begin
                                rsp         <= RSP_NAK;
                                rsp_pending <= 1'b1;
                                frame_ok    <= 1'b0;
                            end
                        end
                    end

                    ST_SGN: begin
                        if (nrx == 4'd1) begin                  // This byte is the checksum
                            st <= ST_SYNC;
                            if ((csum ^ rx_data) == 8'h00) begin
                                in_signed   <= shift[CHANNELS-1:0];
                                rsp         <= RSP_ACK;
                                rsp_pending <= 1'b1;
                                frame_ok    <= 1'b1;
                            end else begin
                                rsp         <= RSP_NAK;
                                rsp_pending <= 1'b1;
                                frame_ok    <= 1'b0;
                            end
                        end
                    end

                    default: st <= ST_SYNC;
                endcase
            end
        end
    end

    // ------------------------------------------------- Status -------------------------------------------------

    reg [24:0] beat = 25'd0;
    always @(posedge clk) beat <= beat + 25'd1;

    assign led[0] = beat[24];           // Heartbeat, proves the MMCM output is running
    assign led[1] = dac_ready;
    assign led[2] = lock_sync[1];
    assign led[3] = frame_ok;
endmodule

`default_nettype wire
