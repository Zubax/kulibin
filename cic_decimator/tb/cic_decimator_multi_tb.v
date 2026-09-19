/// Testbench for cic_decimator_multi.
/// Run via `fusesoc run --target=sim_cic_decimator_multi zubax:kulibin:cic_decimator`.
///
/// Every order of every channel is compared in every cycle against a standalone cic_decimator of that order and width,
/// latched per its own rule (the channel's decimate delayed by the order), cast the same way, and registered when the
/// channel's outputs are due. This proves the integrator sharing, the narrowing, the latch alignment and the output
/// timing, but not the CIC arithmetic itself, which the reference shares with the DUT; that is covered by the
/// full-scale and directed latch checks, whose expected values are computed independently here.

`default_nettype none
`timescale 1ns/1ns

`include "cic_decimator_multi.vh"

module cic_decimator_multi_tb;
    reg clk = 0;
    always #5 clk = !clk;

    wire [4:0] done;

    // 1. The CT arrangement: channel 0 at the tick, channel 1 at the half tick; default (lossless) WOUT = 19.
    cic_decimator_multi_harness #(
        .WIN(1), .RMAX(64), .N(3), .KCOMB(2), .PHASE({8'd32, 8'd0}),
        .SEED(1), .TICKS(200), .RANDOM_CYCLES(20000)
    ) h1 (.clk(clk), .done(done[0]));

    // 2. The same with WOUT = 13: sinc^3 rounded, sinc^2 exact, sinc^1 padded.
    cic_decimator_multi_harness #(
        .WIN(1), .RMAX(64), .N(3), .KCOMB(2), .PHASE({8'd32, 8'd0}), .WOUT(13),
        .SEED(2), .TICKS(100), .RANDOM_CYCLES(20000)
    ) h2 (.clk(clk), .done(done[1]));

    // 3. Stress: small widths wrap often; orders 1..4; a full-scale run below RMAX; the directed checks.
    cic_decimator_multi_harness #(
        .WIN(3), .RMAX(8), .N(4), .KCOMB(3), .PHASE({8'd5, 8'd3, 8'd0}),
        .SEED(3), .TICKS(300), .RANDOM_CYCLES(40000), .R_LOW(7), .DIRECTED(1)
    ) h3 (.clk(clk), .done(done[2]));

    // 4. Odd ratio: G(m) = 3/5/7, DC gains 5/8, 25/32, 125/128.
    cic_decimator_multi_harness #(
        .WIN(2), .RMAX(5), .N(3), .KCOMB(2), .PHASE({8'd2, 8'd0}),
        .SEED(4), .TICKS(400), .RANDOM_CYCLES(20000)
    ) h4 (.clk(clk), .done(done[3]));

    // 5. Degenerate: order 1 only, at the minimum widths; +G = +2 saturates to +1 at WOUT = 2.
    cic_decimator_multi_harness #(
        .WIN(1), .RMAX(2), .N(1), .KCOMB(1),
        .SEED(5), .TICKS(500), .RANDOM_CYCLES(10000)
    ) h5 (.clk(clk), .done(done[4]));

    initial begin
        // Validate the bench's own expectation function against values derived by hand.
        if (h1.expect_q(1 << 18, 19, 19) !== ((1 << 18) - 1))  $fatal(1, "expect_q: sinc3 +FS");
        if (h1.expect_q(-(1 << 18), 19, 19) !== -(1 << 18))    $fatal(1, "expect_q: sinc3 -FS");
        if (h1.expect_q(1 << 12, 13, 19) !== (4095 * 64))       $fatal(1, "expect_q: sinc2 +FS");
        if (h1.expect_q(-(1 << 12), 13, 19) !== -(1 << 18))     $fatal(1, "expect_q: sinc2 -FS");
        if (h1.expect_q(1 << 18, 19, 13) !== 4095)              $fatal(1, "expect_q: sinc3 +FS rounded");
        if (h1.expect_q(-(1 << 18), 19, 13) !== -4096)          $fatal(1, "expect_q: sinc3 -FS rounded");
        if (h1.expect_q(2, 2, 2) !== 1)                         $fatal(1, "expect_q: 2-bit +G");
        if (h1.expect_q(96, 10, 8) !== 24)                      $fatal(1, "expect_q: exact division");
        if (h1.expect_q(98, 10, 8) !== 24)                      $fatal(1, "expect_q: tie to even, down");
        if (h1.expect_q(102, 10, 8) !== 26)                     $fatal(1, "expect_q: tie to even, up");
        if (h1.expect_q(-98, 10, 8) !== -24)                    $fatal(1, "expect_q: negative tie to even");
        if (h1.expect_q(-99, 10, 8) !== -25)                    $fatal(1, "expect_q: negative round down");
        // Pin the output widths, which the bench computes with the DUT's own growth macro, to hand-derived values.
        if ((h1.WO !== 19) || (h2.WO !== 13) || (h3.WO !== 15) || (h4.WO !== 9) || (h5.WO !== 2)) begin
            $fatal(1, "output widths %0d %0d %0d %0d %0d", h1.WO, h2.WO, h3.WO, h4.WO, h5.WO);
        end
        // Literal arguments at the top of the supported range (R^N < 2^32), beyond signed 32-bit arithmetic.
        if (`CIC_DECIMATOR_MULTI_WOUT(1, 255, 4) !== 33) $fatal(1, "CIC_DECIMATOR_MULTI_WOUT overflows");
        wait (&done);
        $display("PASS");
        $finish;
    end
endmodule

/// One DUT instance with its stimulus program and checks.
module cic_decimator_multi_harness#(
    parameter WIN = 1,
    parameter RMAX = 64,
    parameter N = 3,
    parameter KCOMB = 1,
    parameter [8*KCOMB-1:0] PHASE = 0,  // Fixed-ratio latch phase per channel: samples before the tick sample.
    parameter WOUT = 0,                 // Zero leaves the DUT default.
    parameter SEED = 1,
    parameter TICKS = 100,              // Latch periods per fixed-ratio random-data segment.
    parameter RANDOM_CYCLES = 10000,    // Cycles per random-latch segment.
    parameter R_LOW = 0,                // Nonzero adds full-scale segments at this ratio (below RMAX, >= 2N-1).
    parameter DIRECTED = 0              // Run the directed latch-rule checks; needs WIN >= 3.
)(
    input wire clk,
    output reg done
);
    localparam integer WX = (WIN > 1) ? WIN : 2;
    localparam integer WO = (WOUT > 0) ? WOUT : `CIC_DECIMATOR_MULTI_WOUT(WIN, RMAX, N);
    localparam integer IN_MAX = (WIN > 1) ? ((1 << (WIN - 1)) - 1) : 1;
    localparam integer IN_MIN = (WIN > 1) ? (-(1 << (WIN - 1))) : -1;
    localparam integer SPACING = (2 * N) - 1;  // the minimum number of cycles between the decimate pulses of a channel

    // The expected q1.(wout-1) slice for the raw comb value y: saturate to wsat bits, then zero-pad or round to
    // nearest, ties to even, saturating the positive rail. Formulated arithmetically, independently of cast_signed.
    function automatic integer expect_q;
        input integer y;
        input integer wsat;
        input integer wout;
        integer d, q, r;
        begin
            if (y > ((1 << (wsat - 1)) - 1)) y = (1 << (wsat - 1)) - 1;
            if (y < -(1 << (wsat - 1)))      y = -(1 << (wsat - 1));
            if (wout >= wsat) begin
                expect_q = y * (1 << (wout - wsat));
            end else begin
                d = 1 << (wsat - wout);
                q = y / d;
                if ((y < 0) && ((q * d) != y)) q = q - 1;  // floor
                r = y - (q * d);
                if (((2 * r) > d) || (((2 * r) == d) && ((q % 2) != 0))) q = q + 1;
                if (q > ((1 << (wout - 1)) - 1)) q = (1 << (wout - 1)) - 1;
                expect_q = q;
            end
        end
    endfunction

    function automatic integer power;
        input integer b;
        input integer e;
        integer i;
        begin
            power = 1;
            for (i = 0; i < e; i = i + 1) power = power * b;
        end
    endfunction

    // ----------------------------------------------------------------------------------------------------------------
    // DUT. Both branches carry the same label so that the hierarchical references below do not depend on WOUT.

    reg rst = 1;
    reg in_valid = 0;
    reg signed [WIN-1:0] in_data = 0;
    reg [KCOMB-1:0] decimate = 0;
    wire [KCOMB-1:0] out_valid;
    wire [WO*N*KCOMB-1:0] out_data;

    generate
        if (WOUT > 0) begin : g_dut
            cic_decimator_multi #(.WIN(WIN), .RMAX(RMAX), .N(N), .KCOMB(KCOMB), .WOUT(WOUT)) dut (
                .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .decimate(decimate),
                .out_valid(out_valid), .out_data(out_data)
            );
        end else begin : g_dut
            cic_decimator_multi #(.WIN(WIN), .RMAX(RMAX), .N(N), .KCOMB(KCOMB)) dut (
                .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .decimate(decimate),
                .out_valid(out_valid), .out_data(out_data)
            );
        end
    endgenerate

    initial begin
        #1;
        if (g_dut.dut.WOUT != WO) $fatal(1, "DUT WOUT %0d, expected %0d", g_dut.dut.WOUT, WO);
    end

    // The input as a signed integer of WX bits, like the DUT maps it; the full-scale checks pin this mapping down.
    wire signed [WX-1:0] in_x = (WIN == 1) ? (in_data[0] ? -2'sd1 : 2'sd1) : in_data;

    // ----------------------------------------------------------------------------------------------------------------
    // Segment state shared between the stimulus program and the checks.

    integer ratio = RMAX;
    integer plateau_on = 0;      // Constant input from reset at a fixed ratio: check the settled latches.
    integer plateau_value = 0;   // The constant input as an integer.
    integer directed_on = 0;
    integer directed_kind = 0;   // 0: nothing latched; 1: only a = +1 latched; 2: a = +1 then b = +2 latched.
    integer plateau_count [0:(N*KCOMB)-1];
    integer directed_count [0:(N*KCOMB)-1];
    reg [(N*KCOMB)-1:0] wrapped = 0;

    // ----------------------------------------------------------------------------------------------------------------
    // Checks, sampled one time unit after each rising edge.

    genvar k;
    genvar m;
    generate
        for (k = 0; k < KCOMB; k = k + 1) begin : g_chk_channel
            // decimate[k] delayed by 1..2N+1 cycles: the order-m reference latches at dec_line[m-1], the outputs are
            // loaded at dec_line[2N-1] and out_valid[k] must equal dec_line[2N].
            reg [2*N:0] dec_line = 0;
            reg rst_at_edge = 0;
            wire valid = `CIC_DECIMATOR_MULTI_VALID(out_valid, k);
            integer n_valid = 0;   // out_valid[k] pulses since reset
            integer latch_sample;
            always @(posedge clk) begin
                if (rst) begin
                    dec_line <= 0;
                end else begin
                    dec_line <= {dec_line, decimate[k]};
                end
            end
            always @(posedge clk) begin
                rst_at_edge = rst;
                #1;
                if (valid !== dec_line[2*N]) $fatal(1, "channel %0d: out_valid %b, (2N+1)-delayed decimate %b",
                                                  k, valid, dec_line[2*N]);
                if (rst_at_edge) begin
                    n_valid = 0;
                end else if (valid) begin
                    n_valid = n_valid + 1;
                end
                // Fixed-ratio latches from reset fall on samples n*R-p, p = PHASE mod R, counting from 1.
                latch_sample = (n_valid * ratio) - (PHASE[8*k +: 8] % ratio);
            end

            for (m = 1; m <= N; m = m + 1) begin : g_chk_order
                localparam integer M    = m;  // sized, unlike the genvar
                localparam integer G    = `CIC_DECIMATOR_MULTI_GROWTH(RMAX, M);
                localparam integer WC   = WX + G;
                localparam integer WSAT = WIN + G;
                localparam integer IDX  = (N * k) + m - 1;

                // Reference: a standalone order-m CIC latched m cycles later (its rule), cast the same way.
                wire signed [WC-1:0] ref_in = in_x;
                wire ref_valid;
                wire signed [WC-1:0] ref_raw;
                cic_decimator #(.W(WC), .N(m)) ref_cic (
                    .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(ref_in), .decimate(dec_line[m-1]),
                    .out_valid(ref_valid), .out_data(ref_raw)
                );
                wire signed [WO-1:0] ref_cast;
                cast_signed #(.WIN(WC), .MSB(WC - WSAT), .LSB(WSAT - WO)) ref_cast_inst (
                    .din(ref_raw), .dout(ref_cast)
                );
                reg signed [WO-1:0] expected_slice = 0;
                always @(posedge clk) begin
                    if (rst) begin
                        expected_slice <= 0;
                    end else if (dec_line[2*N-1]) begin
                        expected_slice <= ref_cast;
                    end
                end

                wire signed [WO-1:0] slice = `CIC_DECIMATOR_MULTI_DATA(out_data, WO, N, k, m);
                wire signed [WC-1:0] tap_peek = g_dut.dut.integrator[m-1][WC-1:0];

                reg signed [WO-1:0] slice_prev = 0;
                reg signed [WC-1:0] tap_prev = 0;
                reg rst_at_edge = 0;
                integer expected;
                always @(posedge clk) begin
                    rst_at_edge = rst;
                    #2;  // after the channel's check, which counts the out_valid pulses
                    if (slice !== expected_slice) begin
                        $fatal(1, "channel %0d order %0d: slice %0d, reference %0d", k, m, slice, expected_slice);
                    end
                    if ((slice !== slice_prev) && !valid && !rst_at_edge) begin
                        $fatal(1, "channel %0d order %0d: slice changed from %0d to %0d without out_valid",
                               k, m, slice_prev, slice);
                    end
                    if (rst_at_edge && (slice !== 0)) $fatal(1, "channel %0d order %0d: not cleared by reset", k, m);
                    slice_prev = slice;

                    if (!rst_at_edge && valid) begin
                        if ((plateau_on != 0) && (latch_sample >= ((m * (ratio - 1)) + 1))) begin
                            expected = expect_q(plateau_value * power(ratio, m), WSAT, WO);
                            if (slice !== expected) begin
                                $fatal(1, "channel %0d order %0d: full scale %0d, expected %0d (input %0d, R %0d)",
                                       k, m, slice, expected, plateau_value, ratio);
                            end
                            plateau_count[IDX] = plateau_count[IDX] + 1;
                        end
                        if (directed_on != 0) begin
                            expected = (directed_kind == 0) ? 0 : ((directed_kind == 1) ? 1 : (m + 2));
                            expected = expect_q(expected, WSAT, WO);
                            if (slice !== expected) begin
                                $fatal(1, "channel %0d order %0d: directed case %0d gives %0d, expected %0d",
                                       k, m, directed_kind, slice, expected);
                            end
                            directed_count[IDX] = directed_count[IDX] + 1;
                        end
                    end

                    // With a constant positive input the tap only grows, except where it wraps around.
                    if (!rst_at_edge && (plateau_on != 0) && (plateau_value > 0) && (tap_peek < tap_prev)) begin
                        wrapped[IDX] = 1'b1;
                    end
                    tap_prev = tap_peek;
                end
            end
        end
    endgenerate

    // ----------------------------------------------------------------------------------------------------------------
    // Stimulus. Inputs change on the falling edge.

    // A xorshift32 generator. $urandom(seed) is not used because simulators disagree on whether it advances the seed.
    reg [31:0] rng = 32'h2545F491 ^ SEED;

    function automatic integer rnd;  // uniform in [0, n); advances the generator
        input integer n;
        begin
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);
            rnd = rng % n;
        end
    endfunction

    function automatic [WIN-1:0] random_data;
        input integer dummy;
        begin
            random_data = rnd(1 << WIN);
        end
    endfunction

    function automatic [WIN-1:0] code_of;  // the input code of an integer value
        input integer v;
        begin
            if (WIN == 1) code_of = (v < 0) ? 1'b1 : 1'b0;
            else          code_of = v;
        end
    endfunction

    integer i;
    integer c;
    integer sample_count;           // accepted samples since reset
    integer pend [0:KCOMB-1];       // cycles until a scheduled fixed-ratio latch; -1 if none
    integer since [0:KCOMB-1];      // accepted samples since the last latch, for the random mode
    integer quiet [0:KCOMB-1];      // cycles since the last latch, for the random mode

    task automatic idle;
        begin
            in_valid = 0;
            in_data = 0;
            decimate = 0;
        end
    endtask

    task automatic reset_dut;
        input integer cycles;
        begin
            @(negedge clk);
            idle;
            rst = 1;
            repeat (cycles) @(negedge clk);
            rst = 0;
            sample_count = 0;
            for (i = 0; i < KCOMB; i = i + 1) begin
                pend[i] = -1;
                since[i] = 0;
                quiet[i] = SPACING;
            end
        end
    endtask

    task automatic flush;
        begin
            idle;
            repeat ((2 * N) + 3) @(negedge clk);
        end
    endtask

    // Fixed-ratio latching: channel k latches on sample s when (s + PHASE[k]) is a multiple of the ratio. With every
    // 5th cycle valid, the latch is asserted on a random cycle between the sample and the next one, all equivalent.
    // valid_mode: 0 every cycle, 1 every 5th cycle. value: the constant input, or -1000 for random data.
    task automatic run_fixed;
        input integer valid_mode;
        input integer periods;
        input integer value;
        integer cyc;
        begin
            cyc = 0;
            while (sample_count < (periods * ratio)) begin
                in_valid = (valid_mode == 0) || ((cyc % 5) == 0);
                in_data = (value == -1000) ? random_data(0) : code_of(value);
                decimate = 0;
                if (in_valid) begin
                    sample_count = sample_count + 1;
                    for (i = 0; i < KCOMB; i = i + 1) begin
                        if (((sample_count + PHASE[8*i +: 8]) % ratio) == 0) begin
                            pend[i] = (valid_mode == 0) ? 0 : rnd(5);
                        end
                    end
                end
                for (i = 0; i < KCOMB; i = i + 1) begin
                    if (pend[i] == 0) decimate[i] = 1'b1;
                    if (pend[i] >= 0) pend[i] = pend[i] - 1;
                end
                cyc = cyc + 1;
                @(negedge clk);
            end
            // Complete a latch still pending in the gap after the last sample.
            idle;
            for (c = 0; c < 5; c = c + 1) begin
                for (i = 0; i < KCOMB; i = i + 1) begin
                    if (pend[i] == 0) decimate[i] = 1'b1;
                    if (pend[i] >= 0) pend[i] = pend[i] - 1;
                end
                @(negedge clk);
                decimate = 0;
            end
            flush;
        end
    endtask

    // Constant input from reset at a fixed ratio; the checks compare the settled latches with the ideal value.
    task automatic run_plateau;
        input integer r;
        input integer value;
        begin
            ratio = r;
            reset_dut(2);
            for (i = 0; i < (N * KCOMB); i = i + 1) plateau_count[i] = 0;
            wrapped = 0;
            plateau_value = value;
            plateau_on = 1;
            run_fixed(0, N + 5, value);
            plateau_on = 0;
            for (i = 0; i < (N * KCOMB); i = i + 1) begin
                if (plateau_count[i] < 2) $fatal(1, "slice %0d: only %0d full-scale checks", i, plateau_count[i]);
            end
            if ((value > 0) && (wrapped != {(N * KCOMB){1'b1}})) $fatal(1, "not every tap wrapped: %b", wrapped);
            ratio = RMAX;
        end
    endtask

    // Random data and latches at least SPACING cycles apart; each channel is forced to latch once RMAX samples accrue.
    // One reset hits a pending latch while the random stimulus continues. valid_mode: 0 every cycle, 1 every 5th,
    // 2 random.
    task automatic run_random;
        input integer valid_mode;
        input integer cycles;
        integer reset_left;
        integer armed;
        integer coin;
        integer n_valid;
        integer n_ones;
        integer n_dec;
        begin
            reset_left = 0;
            armed = 0;
            n_valid = 0;
            n_ones = 0;
            n_dec = 0;
            for (c = 0; c < cycles; c = c + 1) begin
                if (c == (cycles / 2)) armed = 1;
                coin = rnd(2);
                in_valid = (valid_mode == 0) || ((valid_mode == 1) && ((c % 5) == 0)) ||
                           ((valid_mode == 2) && (coin == 0));
                in_data = random_data(0);
                n_valid = n_valid + in_valid;
                n_ones = n_ones + in_data[0];
                for (i = 0; i < KCOMB; i = i + 1) begin
                    if (in_valid) since[i] = since[i] + 1;
                    coin = rnd(8);
                    decimate[i] = (quiet[i] >= SPACING) && ((since[i] >= RMAX) || (coin == 0));
                    n_dec = n_dec + (coin == 0);
                    if (decimate[i]) begin
                        since[i] = 0;
                        quiet[i] = 1;
                    end else begin
                        quiet[i] = quiet[i] + 1;
                    end
                end
                if (reset_left > 0) begin
                    reset_left = reset_left - 1;
                    rst = (reset_left > 0);
                end else if ((armed != 0) && (decimate != 0)) begin
                    armed = 0;
                    reset_left = 2 + rnd(3);   // rst high from the next cycle, for 2..4 cycles
                end
                @(negedge clk);
                if (reset_left > 0) rst = 1;
            end
            rst = 0;
            flush;
            // Guard against degenerate stimulus: the random choices must actually vary.
            if ((valid_mode == 2) && ((n_valid < ((cycles * 4) / 10)) || (n_valid > ((cycles * 6) / 10)))) begin
                $fatal(1, "degenerate random in_valid: %0d of %0d", n_valid, cycles);
            end
            if ((n_ones < ((cycles * 4) / 10)) || (n_ones > ((cycles * 6) / 10))) begin
                $fatal(1, "degenerate random data: %0d ones in %0d", n_ones, cycles);
            end
            if ((n_dec < ((cycles * KCOMB) / 10)) || (n_dec > ((cycles * KCOMB) / 6))) begin
                $fatal(1, "degenerate random latch draws: %0d in %0d channel-cycles", n_dec, cycles * KCOMB);
            end
        end
    endtask

    // Directed latch-rule check from a fresh reset: zeros, then a = +1 in cycle t0 and b = +2 as the next sample;
    // every channel latches once, `offset` cycles after t0. Dense: -1 -> nothing, 0 -> a, +1 -> a and b.
    // Every 5th cycle: 0 and 4 (the last cycle before b) -> a, 5 -> a and b.
    task automatic run_directed;
        input integer valid_mode;
        input integer offset;
        input integer kind;
        integer t0;
        integer tb;
        begin
            reset_dut(2);
            for (i = 0; i < (N * KCOMB); i = i + 1) directed_count[i] = 0;
            directed_kind = kind;
            directed_on = 1;
            t0 = 10;
            tb = (valid_mode == 0) ? (t0 + 1) : (t0 + 5);
            for (c = 0; c < (t0 + 12); c = c + 1) begin
                in_valid = (valid_mode == 0) || ((c % 5) == 0);
                in_data = (c == t0) ? 1 : ((c == tb) ? 2 : 0);
                decimate = (c == (t0 + offset)) ? {KCOMB{1'b1}} : {KCOMB{1'b0}};
                @(negedge clk);
            end
            flush;
            directed_on = 0;
            for (i = 0; i < (N * KCOMB); i = i + 1) begin
                if (directed_count[i] != 1) $fatal(1, "slice %0d: %0d directed results", i, directed_count[i]);
            end
        end
    endtask

    initial begin
        done = 0;
        for (i = 0; i < (N * KCOMB); i = i + 1) begin
            plateau_count[i] = 0;
            directed_count[i] = 0;
        end
        if ((DIRECTED != 0) && (WIN < 3)) $fatal(1, "directed checks need WIN >= 3");
        if ((RMAX < SPACING) || ((R_LOW > 0) && (R_LOW < SPACING))) $fatal(1, "ratios below 2N-1 violate the spacing");

        // Fixed-ratio random data, every cycle and every 5th cycle.
        reset_dut(3);
        run_fixed(0, TICKS, -1000);
        reset_dut(1);
        run_fixed(1, TICKS, -1000);

        // Full scale at RMAX, and below it if requested.
        run_plateau(RMAX, IN_MAX);
        run_plateau(RMAX, IN_MIN);
        if (R_LOW > 0) begin
            run_plateau(R_LOW, IN_MAX);
            run_plateau(R_LOW, IN_MIN);
        end

        // Random latches: every cycle, every 5th cycle, random input timing.
        reset_dut(2);
        run_random(0, RANDOM_CYCLES);
        run_random(1, RANDOM_CYCLES);
        run_random(2, RANDOM_CYCLES);

        if (DIRECTED != 0) begin
            run_directed(0, -1, 0);
            run_directed(0,  0, 1);
            run_directed(0,  1, 2);
            run_directed(1,  0, 1);
            run_directed(1,  4, 1);
            run_directed(1,  5, 2);
        end

        done = 1;
    end
endmodule
