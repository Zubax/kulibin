/// An asynchronous parallel bus slave module intended for interfacing an FPGA with microcontrollers
/// that support asynchronous external SRAM interface, such as STM32 chips with FMC etc.
/// See summary at https://jia.je/kb/en/hardware/async_sram.html and the STM32 reference manuals.
///
/// READ SEQUENCE
/// 1. The address is set on ebus_addr, and the select and the read signals are asserted externally.
/// 2. When 2-cycle delayed ebus_cs_n and ebus_rd_n are both asserted,
///    the address is latched and forwarded to the internal interface, and req is asserted with we=0.
/// 3. The controller remains idle until ack=1. The external logic must be able to assert ack at least
///    one cycle before the end of the transaction (i.e., before cs or rd go back up).
/// 4. Once ack=1, data_i is latched and forwarded to ebus_data, and req is deasserted.
/// 5. ebus_data is driven until either ebus_cs_n or ebus_rd_n are deasserted, which ends the transaction.
///
/// The read latency is 3+n clock cycles from (!ebus_cs_n && !ebus_rd_n) to the valid ebus_data,
/// where n is the number of cycles since req=1 to ack=1; usually n>0.
/// The address is latched after 2 clock cycles; it does not need to be held afterward.
/// The output is held for up to two additional cycles after ebus_rd_n is deasserted,
/// which limits the bus turnaround time. The FSM will take additional 2 cycles to return back to the
/// idle state, but the master need not wait for it -- the next transaction can start immediately.
///
/// WRITE SEQUENCE
/// 1. The address and data are set on ebus_addr and ebus_data, and the cs and wr signals are asserted externally.
/// 2. When 2-cycle delayed ebus_cs_n and ebus_wr_n are both asserted,
///    the address and data are latched, forwarded to the internal interface, and req is asserted with we=1.
/// 3. The controller remains idle until ack=1. The external logic must be able to assert ack not later than
///    one cycle after the end of the transaction (i.e., after cs or wr go back up).
/// 4. Once ack=1, both req and we are deasserted.
/// 5. The transaction is concluded once either ebus_cs_n or ebus_wr_n are deasserted.
///
/// GENERAL NOTES
/// The internal address and the data output remain latched until the next transaction modifying them,
/// meaning that they remain stable for very long time, which may be useful for the external logic.
///
/// As an example, if the clock frequency is 100 MHz, with a single-cycle read delay,
/// a safe read transaction duration (ebus_rd_n 1->0->1) is >40 ns,
/// and a safe write transaction duration (ebus_wr_n 1->0->1) is >30 ns.
/// The bus turnaround time is >10 ns in this configuration.

`default_nettype none

module async_parallel_bus_slave #(
    parameter DATA_WIDTH  = 16,
    parameter ADDR_WIDTH  = 6
)(
    input wire clk,
    input wire rst,
    // Internal interface.
    // A rising edge on req commands the external logic to read (we=0) or write (we=1) the data.
    // The req is held asserted until ack is asserted. Ack can be wired 1 if all transactions are zero wait state.
    // Ack must be asserted at least one cycle before the bus master completes the access cycle.
    output wire                     req,
    output wire                     we,
    input  wire                     ack,
    output reg  [ADDR_WIDTH-1:0]    addr,
    output reg  [DATA_WIDTH-1:0]    data_o,  // slave reads this when req=1 we=1
    input  wire [DATA_WIDTH-1:0]    data_i,  // slave writes this when req=1 we=0
    // External async bus interface. The control signals are inverted because such is the convention.
    // If there is only one slave on the bus, the chip select can be tied to ground without a physical pin.
    input  wire                     ebus_cs_n,
    input  wire                     ebus_rd_n,
    input  wire                     ebus_wr_n,
    input  wire [ADDR_WIDTH-1:0]    ebus_addr,
    inout  wire [DATA_WIDTH-1:0]    ebus_data,
    // Diagnostic outputs, not mandatory to use.
    output wire                     ebus_oe // High when the module is driving ebus_data.
);
    // The anti-metastability flip-flops also serve as an additional input delay, ensuring that the address and data
    // lines have stabilized by the time we latch them. Thanks to this delay, we don't need an additional signal
    // propagation state in the FSM.
    (* syn_preserve=1, syn_keep=1 *) reg [1:0] sync_cs;
    (* syn_preserve=1, syn_keep=1 *) reg [1:0] sync_rd;
    (* syn_preserve=1, syn_keep=1 *) reg [1:0] sync_wr;
    always @ (posedge clk) begin
        if (rst) begin
            sync_cs <= 0;
            sync_rd <= 0;
            sync_wr <= 0;
        end else begin
            sync_cs <= {sync_cs[0], !ebus_cs_n};
            sync_rd <= {sync_rd[0], !ebus_rd_n};
            sync_wr <= {sync_wr[0], !ebus_wr_n};
        end
    end
    // Synchronized and delayed signals.
    wire e_cs = sync_cs[1];
    wire e_rd = sync_rd[1];
    wire e_wr = sync_wr[1];

    // The main FSM.
    localparam ST_IDLE    = 0;
    localparam ST_RD_WAIT = 2; // 3'b010
    localparam ST_RD_DONE = 3; // 3'b011
    localparam ST_WR_WAIT = 4; // 3'b100
    localparam ST_WR_DONE = 5; // 3'b101

    reg [DATA_WIDTH-1:0] ebus_data_o;
    reg [2:0] state;

    assign ebus_oe = (state == ST_RD_DONE) && e_cs && e_rd && !e_wr;
    assign ebus_data = ebus_oe ? ebus_data_o : {DATA_WIDTH{1'bz}};
    assign req = (state == ST_RD_WAIT) || (state == ST_WR_WAIT);
    assign we  =  state == ST_WR_WAIT;

    always @ (posedge clk) begin
        if (rst) begin
            state       <= ST_IDLE;
            addr        <= 0;
            data_o      <= 0;
            ebus_data_o <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    // The e_ signals are delayed because of the anti-metastability flip-flops,
                    // meaning that by the time they transition, the address and data lines are already stable.
                    if (e_cs && e_rd && !e_wr) begin
                        state   <= ST_RD_WAIT;
                        addr    <= ebus_addr;
                    end else if (e_cs && e_wr && !e_rd) begin
                        state   <= ST_WR_WAIT;
                        addr    <= ebus_addr;
                        data_o  <= ebus_data;
                    end
                end

                ST_RD_WAIT: begin
                    if (ack) begin
                        state       <= ST_RD_DONE;
                        ebus_data_o <= data_i;  // Latch the data so that we don't require the slave to hold it.
                    end
                end

                ST_RD_DONE: begin
                    if (!e_cs || !e_rd) begin
                        state <= ST_IDLE;
                    end
                end

                ST_WR_WAIT: begin
                    if (ack) begin
                        state <= ST_WR_DONE;  // This state is only needed to deassert the write req.
                    end
                end

                ST_WR_DONE: begin
                    if (!e_cs || !e_wr) begin
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    $fatal;
                end
            endcase
        end
    end
endmodule
