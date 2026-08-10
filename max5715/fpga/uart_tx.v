// Minimal UART transmitter for the max5715 bench harness: 8 data bits, no parity, one stop bit, LSB first.
// Not part of the reusable library -- it exists only to acknowledge host commands to the DAC test top level.

`default_nettype none

module uart_tx#(
    parameter CYCLES_PER_BIT = 868      // clk cycles per bit; 100 MHz / 115200 rounds to 868
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,            // Accepted whenever busy is low
    output reg        tx,
    output wire       busy
);
    localparam CW = $clog2(CYCLES_PER_BIT);
    /* verilator lint_off WIDTHTRUNC */
    localparam [CW-1:0] FULL = CYCLES_PER_BIT - 1;
    /* verilator lint_on WIDTHTRUNC */

    generate
        if (CYCLES_PER_BIT < 8) begin : g_chk_bit  uart_tx_error_CYCLES_PER_BIT_lt_8 e();  end
    endgenerate

    reg [CW-1:0] cnt;
    reg [3:0]    bits;
    reg [9:0]    sh;                    // {stop, data[7:0], start}, shifted out from the bottom
    reg          active;

    assign busy = active;

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            tx     <= 1'b1;
            cnt    <= {CW{1'b0}};
            bits   <= 4'd0;
            sh     <= 10'h3FF;
        end else if (!active) begin
            tx <= 1'b1;                             // Idle high
            if (valid) begin
                sh     <= {1'b1, data, 1'b0};
                active <= 1'b1;
                cnt    <= FULL;
                bits   <= 4'd10;
                tx     <= 1'b0;                     // Start bit begins immediately
            end
        end else begin
            tx <= sh[0];
            if (cnt != {CW{1'b0}}) begin
                cnt <= cnt - 1'b1;
            end else begin
                cnt  <= FULL;
                sh   <= {1'b1, sh[9:1]};
                bits <= bits - 1'b1;
                if (bits == 4'd1) active <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
