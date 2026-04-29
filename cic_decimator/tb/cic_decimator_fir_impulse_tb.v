/// Impulse-response testbench for the CIC+FIR decimator.
/// Run via `fusesoc run --target=sim_cic_decimator_fir_impulse zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_fir_impulse_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam DUT_WIN = 2;
    localparam DUT_RCIC = 64;
    localparam DUT_NCIC = 3;
    localparam DUT_NFIR = 5;
    localparam DUT_WOUT = 16;
    localparam DUT_WK = 16;

    localparam FIR_ACCEPTANCE_INTERVAL_CLK = DUT_NFIR + 2;
    localparam CIC_IMPULSE_TICKS = DUT_NCIC * (DUT_RCIC - 1) + 1;
    localparam CIC_IMPULSE_PERIODS = (CIC_IMPULSE_TICKS + DUT_RCIC - 1) / DUT_RCIC;
    localparam FIR_SETTLE_PERIODS = CIC_IMPULSE_PERIODS + DUT_NFIR;
    localparam RUN_TICKS = (FIR_SETTLE_PERIODS + 3) * DUT_RCIC;
    localparam EXPECTED_DECIMATED_SAMPLES = RUN_TICKS / DUT_RCIC;

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

    integer idx;
    integer cic_count = 0;
    integer cic_nonzero_count = 0;
    integer cic_first_nonzero = 0;
    integer cic_last_nonzero = 0;
    integer cic_sample = 0;
    integer fir_count = 0;
    integer fir_nonzero_count = 0;
    integer fir_first_nonzero = 0;
    integer fir_last_nonzero = 0;
    integer fir_sample = 0;

    always @(negedge clk) begin
        if (!rst) begin
            if (dut.cic_out_valid) begin
                cic_count = cic_count + 1;
                cic_sample = $signed(dut.cic_out);
                $display("cic[%0d] = %0d", cic_count - 1, cic_sample);

                if (cic_sample != 0) begin
                    if (cic_nonzero_count == 0) cic_first_nonzero = cic_count;
                    cic_nonzero_count = cic_nonzero_count + 1;
                    cic_last_nonzero = cic_count;
                    `REQUIRE((cic_last_nonzero - cic_first_nonzero + 1) <= CIC_IMPULSE_PERIODS);
                end
            end

            if (out_valid) begin
                fir_count = fir_count + 1;
                fir_sample = out_data;
                $display("fir[%0d] = %0d", fir_count - 1, fir_sample);

                if (fir_sample != 0) begin
                    if (fir_nonzero_count == 0) fir_first_nonzero = fir_count;
                    fir_nonzero_count = fir_nonzero_count + 1;
                    fir_last_nonzero = fir_count;
                    `REQUIRE((fir_last_nonzero - fir_first_nonzero + 1) <= FIR_SETTLE_PERIODS);
                end
            end
        end
    end

    initial begin
        `REQUIRE(DUT_RCIC >= FIR_ACCEPTANCE_INTERVAL_CLK);
        `REQUIRE((RUN_TICKS % DUT_RCIC) == 0);

        rst = 1;
        repeat (2) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        for (idx = 0; idx < RUN_TICKS; idx = idx + 1) begin
            in_valid <= 1'b1;
            in_data <= (idx == 0) ? 2'sd1 : 2'sd0;
            @(negedge clk);
        end
        in_valid <= 1'b0;
        in_data <= 2'sd0;

        repeat (DUT_RCIC) @(negedge clk);

        $display("CIC samples: %0d, nonzero: %0d, first nonzero: %0d, last nonzero: %0d",
                 cic_count, cic_nonzero_count, cic_first_nonzero, cic_last_nonzero);
        $display("FIR samples: %0d, nonzero: %0d, first nonzero: %0d, last nonzero: %0d",
                 fir_count, fir_nonzero_count, fir_first_nonzero, fir_last_nonzero);

        `REQUIRE(cic_count == EXPECTED_DECIMATED_SAMPLES);
        `REQUIRE(fir_count == EXPECTED_DECIMATED_SAMPLES);
        `REQUIRE(cic_nonzero_count > 0);
        `REQUIRE(fir_nonzero_count > 0);
        `REQUIRE((cic_last_nonzero - cic_first_nonzero + 1) <= CIC_IMPULSE_PERIODS);
        `REQUIRE((fir_last_nonzero - fir_first_nonzero + 1) <= FIR_SETTLE_PERIODS);

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_fir_impulse_tb.vcd");
        $dumpvars();
    end
endmodule
