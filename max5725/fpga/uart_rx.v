// Minimal UART receiver for the max5725 bench harness: 8 data bits, no parity, one stop bit, LSB first.
// Not part of the reusable library -- it exists only to give the host a way to drive the DAC test top level.

`default_nettype none

module uart_rx#(
    parameter CYCLES_PER_BIT = 868      // clk cycles per bit; 100 MHz / 115200 rounds to 868
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,               // Asynchronous serial input
    output reg  [7:0] data,
    output reg        valid             // One cycle per correctly framed byte
);
    localparam CW = $clog2(CYCLES_PER_BIT);
    /* verilator lint_off WIDTHTRUNC */
    localparam [CW-1:0] FULL = CYCLES_PER_BIT - 1;
    localparam [CW-1:0] MID  = CYCLES_PER_BIT / 2;
    /* verilator lint_on WIDTHTRUNC */

    generate
        if (CYCLES_PER_BIT < 8) begin : g_chk_bit  uart_rx_error_CYCLES_PER_BIT_lt_8 e();  end
    endgenerate

    (* ASYNC_REG = "TRUE" *) reg [1:0] sync;
    reg [CW-1:0] cnt;
    reg [3:0]    bits;              // 0 = start bit, 1..8 = data bits, 9 = stop bit
    reg          busy;
    reg [7:0]    sh;

    always @(posedge clk) begin
        sync  <= {sync[0], rx};
        valid <= 1'b0;
        if (rst) begin
            sync <= 2'b11;
            busy <= 1'b0;
            cnt  <= {CW{1'b0}};
            bits <= 4'd0;
        end else if (!busy) begin
            if (!sync[1]) begin                 // Falling edge into the start bit
                busy <= 1'b1;
                cnt  <= MID;                    // Realign to the middle of the bit cell
                bits <= 4'd0;
            end
        end else if (cnt != {CW{1'b0}}) begin
            cnt <= cnt - 1'b1;
        end else begin
            cnt <= FULL;
            if (bits == 4'd0) begin
                if (sync[1]) busy <= 1'b0;      // Start bit did not hold: noise, not a frame
                bits <= 4'd1;
            end else if (bits <= 4'd8) begin
                sh   <= {sync[1], sh[7:1]};     // LSB arrives first
                bits <= bits + 1'b1;
            end else begin
                if (sync[1]) begin              // Valid stop bit, so the byte is good
                    data  <= sh;
                    valid <= 1'b1;
                end
                busy <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
