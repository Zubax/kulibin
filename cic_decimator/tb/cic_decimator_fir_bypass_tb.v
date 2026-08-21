/// CIC+FIR wrapper testbench for the FIR-disabled special case (NFIR=0), where the CIC output is the module output.
/// The DUTs deliberately do not override KERNEL, and the fileset carries no kernel file: if the FIR were still
/// instantiated, it would try to read the nonexistent default kernel and convolve X, so every value assertion below
/// would fail and the simulator would report the failed $readmemb.
/// The three signed DUTs differ in the output width, so that the pass-through, the rounding, and the
/// LSB-padding branches of the output cast are all exercised; the two single-bit DUTs add saturation, alone and
/// combined with rounding.
/// The assertions use case equality so that an X -- which is what a wrongly instantiated FIR would produce --
/// is a failure rather than a silently accepted unknown.
/// Run via `fusesoc run --target=sim_cic_decimator_fir_bypass zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_fir_bypass_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam RCIC = 4;
    localparam NCIC = 3;
    localparam NFIR = 0;                        // the whole point of this bench
    localparam SIGNED_WIN = 3;
    localparam EXACT_WOUT = 9;                  // == WSAT: neither rounding nor padding
    localparam ROUND_WOUT = 7;                  // narrower than WSAT: rounding-to-nearest, ties-to-even
    localparam ROUND_WK = 16;                   // wide coefficients; must be ignored while the FIR is disabled
    localparam PAD_WOUT = 11;                   // wider than WSAT: LSB zero-padding
    localparam PAD_SHIFT = PAD_WOUT - EXACT_WOUT;
    localparam BIT_WIN = 1;
    localparam BIT_WOUT = 7;
    localparam SAT_WOUT = 5;                    // WIN=1 narrowed below WSAT: saturation and rounding both act
    localparam RUN_PERIODS = 10;
    localparam RUN_CYCLES = RUN_PERIODS * RCIC;
    localparam IMPULSE_PERIODS = 8;
    localparam IMPULSE_CYCLES = IMPULSE_PERIODS * RCIC;
    localparam RESPONSE_LAST = NCIC * (RCIC - 1);
    localparam RESPONSE_PHASE = RCIC - 1;
    localparam RESPONSE_GAIN = RCIC ** (NCIC - 1);
    localparam TOTAL_DELAY_NUMERATOR = NCIC * (RCIC - 1) + NFIR * RCIC;

    reg rst = 0;
    reg signed_in_valid = 0;
    reg signed [SIGNED_WIN-1:0] signed_in_data = 0;
    wire exact_out_valid;
    wire signed [EXACT_WOUT-1:0] exact_out_data;
    wire round_out_valid;
    wire signed [ROUND_WOUT-1:0] round_out_data;
    wire pad_out_valid;
    wire signed [PAD_WOUT-1:0] pad_out_data;

    reg bit_in_valid = 0;
    reg signed [BIT_WIN-1:0] bit_in_data = 0;
    wire bit_out_valid;
    wire signed [BIT_WOUT-1:0] bit_out_data;
    wire sat_out_valid;
    wire signed [SAT_WOUT-1:0] sat_out_data;

    cic_decimator_fir#(
        .WIN(SIGNED_WIN),
        .RCIC(RCIC),
        .NCIC(NCIC),
        .NFIR(NFIR),
        .WOUT(EXACT_WOUT)
    ) dut_exact (
        .clk(clk),
        .rst(rst),
        .in_valid(signed_in_valid),
        .in_data(signed_in_data),
        .out_valid(exact_out_valid),
        .out_data(exact_out_data)
    );

    cic_decimator_fir#(
        .WIN(SIGNED_WIN),
        .RCIC(RCIC),
        .NCIC(NCIC),
        .NFIR(NFIR),
        .WOUT(ROUND_WOUT),
        .WK(ROUND_WK)   // makes WFIR wider than WOUT; irrelevant here, but not if the FIR were still in the path
    ) dut_round (
        .clk(clk),
        .rst(rst),
        .in_valid(signed_in_valid),
        .in_data(signed_in_data),
        .out_valid(round_out_valid),
        .out_data(round_out_data)
    );

    cic_decimator_fir#(
        .WIN(SIGNED_WIN),
        .RCIC(RCIC),
        .NCIC(NCIC),
        .NFIR(NFIR),
        .WOUT(PAD_WOUT)
    ) dut_pad (
        .clk(clk),
        .rst(rst),
        .in_valid(signed_in_valid),
        .in_data(signed_in_data),
        .out_valid(pad_out_valid),
        .out_data(pad_out_data)
    );

    cic_decimator_fir#(
        .WIN(BIT_WIN),
        .RCIC(RCIC),
        .NCIC(NCIC),
        .NFIR(NFIR),
        .WOUT(BIT_WOUT)
    ) dut_bit (
        .clk(clk),
        .rst(rst),
        .in_valid(bit_in_valid),
        .in_data(bit_in_data),
        .out_valid(bit_out_valid),
        .out_data(bit_out_data)
    );

    // Unlike the others, this one needs both MSB and LSB trimming, so its cast takes the two-stage path and its
    // output lags the rest by one clk; hence the separate counters below.
    cic_decimator_fir#(
        .WIN(BIT_WIN),
        .RCIC(RCIC),
        .NCIC(NCIC),
        .NFIR(NFIR),
        .WOUT(SAT_WOUT)
    ) dut_satround (
        .clk(clk),
        .rst(rst),
        .in_valid(bit_in_valid),
        .in_data(bit_in_data),
        .out_valid(sat_out_valid),
        .out_data(sat_out_data)
    );

    // The disabled FIR must leave every DUT's output a plain wire from its saturating/rounding cast, whichever
    // cast variant that DUT instantiates; anything interposed between the two breaks these.
    always @(negedge clk) begin
        `REQUIRE(exact_out_valid === dut_exact.cast_out_valid);
        `REQUIRE(exact_out_data  === dut_exact.cast_out);
        `REQUIRE(round_out_valid === dut_round.cast_out_valid);
        `REQUIRE(round_out_data  === dut_round.cast_out);
        `REQUIRE(pad_out_valid   === dut_pad.cast_out_valid);
        `REQUIRE(pad_out_data    === dut_pad.cast_out);
        `REQUIRE(bit_out_valid   === dut_bit.cast_out_valid);
        `REQUIRE(bit_out_data    === dut_bit.cast_out);
        `REQUIRE(sat_out_valid   === dut_satround.cast_out_valid);
        `REQUIRE(sat_out_data    === dut_satround.cast_out);
        // dut_satround is the only DUT with a two-stage cast, so that extra cycle must still be visible at the
        // output: it can never pulse together with the otherwise identically-fed single-stage dut_bit.
        `REQUIRE(!((sat_out_valid === 1'b1) && (bit_out_valid === 1'b1)));
    end

    integer cycle = 0;
    integer out_count = 0;
    integer stable_count = 0;
    integer coeff_index = 0;
    integer impulse_sum = 0;
    integer impulse_moment = 0;
    integer pad_sum = 0;
    integer pad_moment = 0;
    integer sat_count = 0;
    integer sat_stable = 0;

    function automatic integer binom;
        input integer n;
        input integer k;
        integer idx;
        integer acc;
        begin
            if ((k < 0) || (k > n)) begin
                binom = 0;
            end else begin
                acc = 1;
                for (idx = 1; idx <= k; idx = idx + 1) begin
                    acc = (acc * (n - k + idx)) / idx;
                end
                binom = acc;
            end
        end
    endfunction

    function automatic integer cic_coeff;
        input integer index;
        integer term;
        integer acc;
        integer limited_index;
        begin
            acc = 0;
            if ((index >= 0) && (index <= RESPONSE_LAST)) begin
                for (term = 0; term <= NCIC; term = term + 1) begin
                    limited_index = index - term * RCIC;
                    if (limited_index >= 0) begin
                        if ((term % 2) == 0) begin
                            acc = acc + binom(NCIC, term) * binom(limited_index + NCIC - 1, NCIC - 1);
                        end else begin
                            acc = acc - binom(NCIC, term) * binom(limited_index + NCIC - 1, NCIC - 1);
                        end
                    end
                end
            end
            cic_coeff = acc;
        end
    endfunction

    /// The rounded output is stated explicitly instead of being recomputed here, so that the bench cannot share a
    /// rounding mistake with the RTL. The decimated CIC impulse response is [10, 6]; dropping the two LSBs makes
    /// both an exact tie (2.5 and 1.5), and ties-to-even resolves both to 2. This is checked against cic_coeff below.
    function automatic integer expected_round_sample;
        input integer index;
        begin
            case (index)
                RESPONSE_PHASE:        expected_round_sample = 2;
                RESPONSE_PHASE + RCIC: expected_round_sample = 2;
                default:               expected_round_sample = 0;
            endcase
        end
    endfunction

    task automatic reset_case;
        begin
            rst <= 1'b1;
            signed_in_valid <= 1'b0;
            signed_in_data <= 0;
            bit_in_valid <= 1'b0;
            bit_in_data <= 0;
            repeat (2) @(negedge clk);
            rst <= 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    /// All three signed DUTs see the same stimulus, so their outputs are checked together.
    task automatic run_signed_constant;
        input signed [SIGNED_WIN-1:0] sample;
        input integer expected_exact;
        input integer expected_round;
        input integer expected_pad;
        begin
            reset_case;
            out_count = 0;
            stable_count = 0;

            for (cycle = 0; cycle < RUN_CYCLES; cycle = cycle + 1) begin
                signed_in_valid <= 1'b1;
                signed_in_data <= sample;
                bit_in_valid <= 1'b0;
                bit_in_data <= 0;

                @(posedge clk);
                #1;

                `REQUIRE(round_out_valid === exact_out_valid);
                `REQUIRE(pad_out_valid === exact_out_valid);
                if (exact_out_valid) begin
                    out_count = out_count + 1;
                    if (out_count > (NCIC + NFIR + 1)) begin
                        `REQUIRE(exact_out_data === expected_exact);
                        `REQUIRE(round_out_data === expected_round);
                        `REQUIRE(pad_out_data === expected_pad);
                        stable_count = stable_count + 1;
                    end
                end
                `REQUIRE(bit_out_valid === 1'b0);
                `REQUIRE(sat_out_valid === 1'b0);

                @(negedge clk);
            end

            signed_in_valid <= 1'b0;
            signed_in_data <= 0;
            `REQUIRE(stable_count > 0);
        end
    endtask

    task automatic run_bit_constant;
        input sample;
        input integer expected;
        input integer expected_sat;
        begin
            reset_case;
            out_count = 0;
            stable_count = 0;
            sat_count = 0;
            sat_stable = 0;

            for (cycle = 0; cycle < RUN_CYCLES; cycle = cycle + 1) begin
                signed_in_valid <= 1'b0;
                signed_in_data <= 0;
                bit_in_valid <= 1'b1;
                bit_in_data <= sample;

                @(posedge clk);
                #1;

                `REQUIRE(exact_out_valid === 1'b0);
                `REQUIRE(round_out_valid === 1'b0);
                `REQUIRE(pad_out_valid === 1'b0);
                if (bit_out_valid) begin
                    out_count = out_count + 1;
                    if (out_count > (NCIC + NFIR + 1)) begin
                        `REQUIRE(bit_out_data === expected);
                        stable_count = stable_count + 1;
                    end
                end
                if (sat_out_valid) begin
                    sat_count = sat_count + 1;
                    if (sat_count > (NCIC + NFIR + 1)) begin
                        `REQUIRE(sat_out_data === expected_sat);
                        sat_stable = sat_stable + 1;
                    end
                end

                @(negedge clk);
            end

            bit_in_valid <= 1'b0;
            bit_in_data <= 0;
            `REQUIRE(stable_count > 0);
            `REQUIRE(sat_stable > 0);
        end
    endtask

    task automatic check_impulse_sample;
        begin
            coeff_index = RESPONSE_PHASE + out_count * RCIC;
            `REQUIRE(round_out_valid === exact_out_valid);
            `REQUIRE(pad_out_valid === exact_out_valid);
            `REQUIRE(exact_out_data === cic_coeff(coeff_index));
            `REQUIRE(pad_out_data === (cic_coeff(coeff_index) << PAD_SHIFT));
            `REQUIRE(round_out_data === expected_round_sample(coeff_index));
            impulse_sum = impulse_sum + exact_out_data;
            impulse_moment = impulse_moment + exact_out_data * coeff_index;
            pad_sum = pad_sum + pad_out_data;
            pad_moment = pad_moment + pad_out_data * coeff_index;
            $display("y[%0d] = %0d (round %0d, pad %0d)", coeff_index, exact_out_data, round_out_data, pad_out_data);
            out_count = out_count + 1;
        end
    endtask

    /// Without the FIR the decimated impulse response is the bare CIC one, so the DC gain and the group delay
    /// follow the closed-form CIC expressions. The rounded DUT is excluded from the aggregate checks because
    /// rounding breaks their exact linearity.
    task automatic run_impulse_case;
        begin
            reset_case;
            out_count = 0;
            impulse_sum = 0;
            impulse_moment = 0;
            pad_sum = 0;
            pad_moment = 0;

            for (cycle = 0; cycle < IMPULSE_CYCLES; cycle = cycle + 1) begin
                signed_in_valid <= 1'b1;
                signed_in_data <= (cycle == 0) ? 3'sd1 : 3'sd0;
                bit_in_valid <= 1'b0;
                bit_in_data <= 0;

                @(posedge clk);
                #1;

                if (exact_out_valid) check_impulse_sample;
                `REQUIRE(bit_out_valid === 1'b0);
                `REQUIRE(sat_out_valid === 1'b0);

                @(negedge clk);
            end

            signed_in_valid <= 1'b0;
            signed_in_data <= 0;

            repeat (20) begin
                @(posedge clk);
                #1;
                if (exact_out_valid) check_impulse_sample;
                `REQUIRE(bit_out_valid === 1'b0);
                `REQUIRE(sat_out_valid === 1'b0);
                @(negedge clk);
            end

            `REQUIRE(out_count === IMPULSE_PERIODS);
            `REQUIRE(impulse_sum === RESPONSE_GAIN);
            `REQUIRE(pad_sum === (RESPONSE_GAIN << PAD_SHIFT));
            `REQUIRE((2 * impulse_moment) === (impulse_sum * TOTAL_DELAY_NUMERATOR));
            `REQUIRE((2 * pad_moment) === (pad_sum * TOTAL_DELAY_NUMERATOR));
        end
    endtask

    initial begin
        // The expectations below are tied to this configuration; the hardcoded rounded samples especially.
        `REQUIRE(EXACT_WOUT == (SIGNED_WIN + $clog2(RCIC ** NCIC)));
        `REQUIRE(cic_coeff(RESPONSE_PHASE) == 10);
        `REQUIRE(cic_coeff(RESPONSE_PHASE + RCIC) == 6);

        run_signed_constant(3'sd3,   192,  48,  768);
        run_signed_constant(-3'sd4, -256, -64, -1024);
        run_bit_constant(1'b0,  63,  15);
        run_bit_constant(1'b1, -64, -16);
        run_impulse_case;

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_fir_bypass_tb.vcd");
        $dumpvars();
    end
endmodule
