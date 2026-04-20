/// iverilog -Wall -Wno-timescale -y. async_parallel_bus_slave_integration_tb.v && vvp a.out

`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module slave(
    input wire       clk,
    input wire       rst,
    input wire       ebus_cs_n,
    input wire       ebus_rd_n,
    input wire       ebus_wr_n,
    input wire [1:0] ebus_addr,
    inout wire [7:0] ebus_data
);
    wire req;
    wire we;
    reg ack;
    wire [1:0] addr;
    reg  [7:0] data_rd;
    wire [7:0] data_wr;
    reg busy;  // The busy flag is used essentially for req edge detection.

    async_parallel_bus_slave #(.DATA_WIDTH(8), .ADDR_WIDTH(2)) apb_slave (
        .clk(clk),
        .rst(rst),
        // internal
        .req(req),
        .we(we),
        .ack(ack),
        .addr(addr),
        .data_i(data_rd),
        .data_o(data_wr),
        // external
        .ebus_cs_n(ebus_cs_n),
        .ebus_rd_n(ebus_rd_n),
        .ebus_wr_n(ebus_wr_n),
        .ebus_addr(ebus_addr),
        .ebus_data(ebus_data),
        .ebus_oe()
    );

    reg [7:0] reg_a;
    reg [7:0] reg_b;

    wire do_rd = req & !we & !busy;
    wire do_wr = req & we & !busy;

    always @(posedge clk) begin
        if (rst) begin
            ack <= 0;
            busy <= 0;
            data_rd <= 0;
            reg_a <= 8'hAA;
            reg_b <= 8'hBB;
        end else begin
            if (do_rd) begin
                busy <= 1;
                ack <= 1;
                case (addr)  // verilog_lint: waive case-missing-default
                    0: data_rd <=  reg_a;
                    1: data_rd <=  reg_b;
                    2: data_rd <= ~reg_a;
                    3: data_rd <= ~reg_b;
                endcase
            end else if (do_wr) begin
                busy <= 1;
                ack <= 1;
                case (addr)  // verilog_lint: waive case-missing-default
                    0: reg_a <=  data_wr;
                    1: reg_b <=  data_wr;
                    2: reg_a <= ~data_wr;
                    3: reg_b <= ~data_wr;
                endcase
            end else begin
                if (!req) begin
                    busy <= 0;
                    ack <= 0;
                end
            end
        end
    end
endmodule

module async_parallel_bus_slave_integration_tb;
    reg clk = 0;
    always #5 clk = !clk;

    reg rst = 0;

    reg         ebus_cs_n = 1;
    reg         ebus_rd_n = 1;
    reg         ebus_wr_n = 1;
    reg  [1:0]  ebus_addr   = 0;
    reg  [7:0]  ebus_data_drive = 8'bzzzzzzzz;
    wire [7:0]  ebus_data_sense;
    wire [7:0]  ebus_data;

    assign ebus_data = ebus_data_drive;
    assign ebus_data_sense = ebus_data;

    slave slv(
        .clk(clk),
        .rst(rst),
        .ebus_cs_n(ebus_cs_n),
        .ebus_rd_n(ebus_rd_n),
        .ebus_wr_n(ebus_wr_n),
        .ebus_addr(ebus_addr),
        .ebus_data(ebus_data)
    );

    initial begin
        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // ============================================================================================================
        // INITIAL READ TEST

        ebus_addr = 0;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        repeat (4) @(negedge clk);
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        repeat (1) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'hAA);
        repeat (1) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);

        ebus_addr = 1;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        repeat (5) @(negedge clk);
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        `REQUIRE(ebus_data_sense === 8'hBB);
        repeat (2) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);

        ebus_addr = 2;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        repeat (6) @(negedge clk);
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        `REQUIRE(ebus_data_sense === 8'h55);
        repeat (2) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);

        ebus_addr = 3;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        repeat (4) @(negedge clk);
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        repeat (1) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'h44);
        repeat (1) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);

        // ============================================================================================================
        // MODIFY VALUES

        ebus_addr = 0;
        ebus_cs_n = 0;
        ebus_wr_n = 0;
        ebus_data_drive = 8'h19;
        repeat (3) @(negedge clk);
        ebus_cs_n = 1;
        ebus_wr_n = 1;
        ebus_data_drive = 8'bzzzzzzzz;
        repeat (1) @(negedge clk);

        ebus_addr = 3;
        ebus_cs_n = 0;
        ebus_wr_n = 0;
        ebus_data_drive = 8'hA1;
        repeat (3) @(negedge clk);
        ebus_cs_n = 1;
        ebus_wr_n = 1;
        ebus_data_drive = 8'bzzzzzzzz;
        repeat (1) @(negedge clk);

        // ============================================================================================================
        // READ BACK

        ebus_addr = 2;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        repeat (4) @(negedge clk);
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        repeat (1) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'hE6);
        repeat (1) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);

        ebus_addr = 1;
        ebus_cs_n = 0;
        ebus_rd_n = 0;
        ebus_data_drive = 8'bzzzzzzzz;
        repeat (4) @(negedge clk);
        ebus_cs_n = 1;
        ebus_rd_n = 1;
        repeat (1) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'h5E);
        repeat (1) @(negedge clk);
        `REQUIRE(ebus_data_sense === 8'bzzzzzzzz);

        // ============================================================================================================
        // Wrap up.
        @(negedge clk);
        $finish;
    end

    initial begin
        $dumpfile("async_parallel_bus_slave_integration_tb.vcd");
        $dumpvars();
    end
endmodule
