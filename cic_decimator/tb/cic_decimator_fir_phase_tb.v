/// CIC+FIR wrapper decimation phase testbench.
/// Run via `fusesoc run --target=sim_cic_decimator_fir_phase zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_fir_phase_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam DUT_WIN = 8;
    localparam DUT_RCIC = 4;
    localparam DUT_NCIC = 3;
    localparam DUT_NFIR = 5;
    localparam DUT_WOUT = 16;
    localparam DUT_WK = 16;

    localparam TERMINAL_INPUT_CYCLE = DUT_RCIC - 1;
    localparam STANDALONE_CIC_COMB_DELAY = DUT_NCIC - 1;
    localparam EXPECTED_CIC_OUT_CYCLE = TERMINAL_INPUT_CYCLE + DUT_NCIC + STANDALONE_CIC_COMB_DELAY;
    localparam RUN_CYCLES = EXPECTED_CIC_OUT_CYCLE + 4;

    reg rst = 0;
    reg in_valid = 0;
    reg signed [DUT_WIN-1:0] in_data = 0;
    wire out_valid;
    wire signed [DUT_WOUT-1:0] out_data;

    cic_decimator_fir#(
        .WIN(DUT_WIN),
        .RCIC(DUT_RCIC),
        .NCIC(DUT_NCIC),
        .NFIR(DUT_NFIR),
        .WOUT(DUT_WOUT),
        .WK(DUT_WK),
        .KERNEL("147d03e66aec665a.fir.memb")
    ) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_data(in_data),
        .out_valid(out_valid),
        .out_data(out_data)
    );

    integer cycle = 0;
    integer cic_count = 0;
    integer cic_sample = 0;

    initial begin
        rst = 1'b1;
        repeat (2) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        for (cycle = 0; cycle < RUN_CYCLES; cycle = cycle + 1) begin
            in_valid <= (cycle < DUT_RCIC);
            in_data <= (cycle == TERMINAL_INPUT_CYCLE) ? 8'sd1 : 8'sd0;

            @(posedge clk);
            #1;

            if (dut.cic_out_valid) begin
                cic_count = cic_count + 1;
                cic_sample = $signed(dut.cic_out);
                $display("cic_out at cycle %0d = %0d", cycle, cic_sample);
                `REQUIRE(cycle == EXPECTED_CIC_OUT_CYCLE);
                `REQUIRE(cic_sample == 1);
            end else begin
                `REQUIRE(cycle != EXPECTED_CIC_OUT_CYCLE);
            end

            @(negedge clk);
        end

        in_valid <= 1'b0;
        in_data <= 0;

        `REQUIRE(cic_count == 1);

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_fir_phase_tb.vcd");
        $dumpvars();
    end
endmodule
