/// iverilog -Wall -Wno-timescale -y. async_parallel_bus_slave_tb.v && vvp a.out

`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module async_parallel_bus_slave_tb;
    reg clk = 0;
    always #5 clk = !clk;

    reg rst = 0;

    // Internal bus signals.
    wire        req;
    wire        we;
    reg         ack = 0;
    wire [2:0]  addr;
    reg  [7:0]  data_rd = 8'hzz;
    wire [7:0]  data_wr;

    // External bus signals.
    reg         ebus_cs_n = 1;
    reg         ebus_rd_n = 1;
    reg         ebus_wr_n = 1;
    reg  [2:0]  ebus_addr   = 0;
    reg  [7:0]  ebus_data_drive = 8'bzzzzzzzz;
    wire [7:0]  ebus_data_sense;
    wire [7:0]  ebus_data;

    assign ebus_data = ebus_data_drive;
    assign ebus_data_sense = ebus_data;

    async_parallel_bus_slave #(.DATA_WIDTH(8), .ADDR_WIDTH(3)) apb_slave (
        .clk(clk),
        .rst(rst),
        .req(req),
        .we(we),
        .ack(ack),
        .addr(addr),
        .data_i(data_rd),
        .data_o(data_wr),
        .ebus_cs_n(ebus_cs_n),
        .ebus_rd_n(ebus_rd_n),
        .ebus_wr_n(ebus_wr_n),
        .ebus_addr(ebus_addr),
        .ebus_data(ebus_data),
        .ebus_oe()
    );

    wire is_idle = !req && !we && (ebus_data_sense === 8'bzzzzzzzz);

    initial begin
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // READ TEST with normal transaction completion, zero wait cycles.
        `REQUIRE(is_idle);
        ebus_addr = 3'b001;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        // Ensure the read request is asserted after 3 clock cycles.
        repeat (3) @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(!we);
        `REQUIRE(addr == 3'b001);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        data_rd = 8'hde;
        ack = 1;
        // The request is deasserted after the next clock cycle and the valid data is available.
        @(negedge clk);
        data_rd = 8'hzz;
        `REQUIRE(ebus_data_sense === 8'hde);
        `REQUIRE(!req);
        `REQUIRE(!we);
        // Reset the bus.
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        repeat (2) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        @(negedge clk);
        `REQUIRE(apb_slave.state == 0);
        `REQUIRE(is_idle);

        // ============================================================================================================

        // READ TEST with premature transaction completion before the data output can be driven, zero wait cycles.
        `REQUIRE(is_idle);
        ebus_addr = 3'b010;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        data_rd = 8'hbc;
        ack = 1;
        // Ensure the read request is asserted after 3 clock cycles. The bus is reset early.
        @(negedge clk);
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        @(negedge clk);
        @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(!we);
        `REQUIRE(addr == 3'b010);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        // The request is deasserted after the next clock cycle but no data is written out.
        @(negedge clk);
        data_rd = 8'hzz;
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        `REQUIRE(!req);
        `REQUIRE(!we);
        // The bus is reset.
        @(negedge clk);
        `REQUIRE(apb_slave.state == 0);
        `REQUIRE(is_idle);

        // ============================================================================================================

        // READ TEST with normal transaction completion and some wait cycles.
        `REQUIRE(is_idle);
        ebus_addr = 3'b110;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        data_rd = 8'hzz;
        ack = 0;
        // Ensure the read request is asserted after 3 clock cycles.
        repeat (3) @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(!we);
        `REQUIRE(addr == 3'b110);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        // Wait cycles, FSM stalled.
        @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(!we);
        `REQUIRE(addr == 3'b110);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(!we);
        `REQUIRE(addr == 3'b110);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(!we);
        `REQUIRE(addr == 3'b110);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        data_rd = 8'hb4;
        ack = 1;
        // The request is deasserted after the next clock cycle and the valid data is available.
        @(negedge clk);
        data_rd = 8'hzz;
        `REQUIRE(ebus_data_sense == 8'hb4);
        `REQUIRE(!req);
        `REQUIRE(!we);
        // Reset the bus.
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        repeat (2) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        @(negedge clk);
        `REQUIRE(apb_slave.state == 0);
        `REQUIRE(is_idle);

        // ============================================================================================================

        // WRITE TEST with normal transaction completion, zero wait cycles.
        `REQUIRE(is_idle);
        ebus_addr = 3'b100;
        ebus_data_drive = 8'hab;
        ebus_cs_n = 0;
        ebus_wr_n = 0;
        ack = 1;
        // Ensure the write request is asserted after 3 clock cycles with the correct data.
        repeat (3) @(negedge clk);
        ebus_data_drive = 8'bzzzzzzzz;  // Release the data bus. The data is supposed to be latched.
        `REQUIRE(req);
        `REQUIRE(we);
        `REQUIRE(data_wr == 8'hab);
        `REQUIRE(addr == 3'b100);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        // The request is deasserted after the next clock cycle.
        @(negedge clk);
        `REQUIRE(!req);
        `REQUIRE(!we);
        // Reset the bus.
        ebus_cs_n = 1;
        ebus_wr_n = 1;
        @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        repeat (2) @(negedge clk);
        `REQUIRE(apb_slave.state == 0);
        `REQUIRE(is_idle);

        // ============================================================================================================

        // WRITE TEST with fast transaction completion, zero wait cycles.
        `REQUIRE(is_idle);
        ebus_addr = 3'b101;
        ebus_data_drive = 8'h78;
        ebus_cs_n = 0;
        ebus_wr_n = 0;
        ack = 1;
        // Ensure the write request is asserted after 3 clock cycles with the correct data.
        repeat (3) @(negedge clk);
        ebus_cs_n = 1;
        ebus_wr_n = 1;
        ebus_data_drive = 8'bzzzzzzzz;  // Release the data bus. The data is supposed to be latched.
        `REQUIRE(req);
        `REQUIRE(we);
        `REQUIRE(data_wr == 8'h78);
        `REQUIRE(addr == 3'b101);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        // The request is deasserted after the next clock cycle.
        @(negedge clk);
        `REQUIRE(!req);
        `REQUIRE(!we);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        repeat (2) @(negedge clk);
        `REQUIRE(apb_slave.state == 0);
        `REQUIRE(is_idle);

        // ============================================================================================================

        // WRITE TEST with wait cycles.
        `REQUIRE(is_idle);
        ebus_addr = 3'b111;
        ebus_data_drive = 8'h67;
        ebus_cs_n = 0;
        ebus_wr_n = 0;
        ack = 0;
        // Ensure the write request is asserted after 3 clock cycles with the correct data.
        repeat (3) @(negedge clk);
        ebus_cs_n = 1;
        ebus_wr_n = 1;
        ebus_data_drive = 8'bzzzzzzzz;  // Release the data bus. The data is supposed to be latched.
        `REQUIRE(req);
        `REQUIRE(we);
        `REQUIRE(data_wr == 8'h67);
        `REQUIRE(addr == 3'b111);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        // Hold ack low for a few more cycles; the FSM will be stalled.
        @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(we);
        `REQUIRE(data_wr == 8'h67);
        `REQUIRE(addr == 3'b111);
        @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(we);
        `REQUIRE(data_wr == 8'h67);
        `REQUIRE(addr == 3'b111);
        @(negedge clk);
        `REQUIRE(req);
        `REQUIRE(we);
        `REQUIRE(data_wr == 8'h67);
        `REQUIRE(addr == 3'b111);
        ack = 1;
        // The request is deasserted after the next clock cycle.
        @(negedge clk);
        `REQUIRE(!req);
        `REQUIRE(!we);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);
        repeat (2) @(negedge clk);
        `REQUIRE(apb_slave.state == 0);
        `REQUIRE(is_idle);

        // Wrap up.
        @(negedge clk);
        $finish;
    end

    initial begin
        $dumpfile("async_parallel_bus_slave_tb.vcd");
        $dumpvars();
    end
endmodule
