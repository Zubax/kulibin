/// iverilog -Wall -Wno-timescale -y. counter_tb.v && vvp a.out
///
/// Exhaustive one-cycle transition check of the counter against a reference model, plus a randomized run of the
/// compare channels (NCHAN=2) with coverage of matches at zero, mid-period, at the top, and of the sampled compare.

`timescale 1ns/1ns
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module counter_tb;
    localparam W = 4;
    localparam STATE_COUNT = 1 << W;

    reg clk = 0;
    always #5 clk = !clk;

    reg         rst    = 0;
    reg         enable = 0;
    reg [W-1:0] top    = 0;
    reg [W-1:0] cmp0   = 0;
    reg [W-1:0] cmp1   = 0;

    wire [W-1:0] count;
    wire         at_top;
    wire         at_bot;
    reg [W-1:0] expected_count = 0;
    reg [W-1:0] expected_top   = 0;
    reg [W-1:0] expected_cmp0  = 0;
    reg [W-1:0] expected_cmp1  = 0;
    integer cov_cmp_zero   = 0;
    integer cov_cmp_mid    = 0;
    integer cov_cmp_top    = 0;
    integer cov_cmp_sample = 0;
    reg [STATE_COUNT-1:0] seen [0:STATE_COUNT-1];
    integer clock_cycles_checked = 0;
    integer transition_cases_checked = 0;
    integer init_index;
    integer state_top;
    integer state_count;

    // Stimulus randomness: a xorshift32 generator, as in counter_prescaler_tb.
    reg [31:0] rng = 32'h2545F491;
    function automatic integer rnd;  // uniform in [0, n)
        input integer n;
        begin
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);
            rnd = rng % n;
        end
    endfunction

    counter#(.W(W)) dut(
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .top(top),
        .cmp({W{1'b0}}),
        .count(count),
        .at_top(at_top),
        .at_bot(at_bot),
        .at_cmp()
    );

    // The compare channels must not change the base counter behavior.
    wire [W-1:0] cmp_count;
    wire         cmp_at_top;
    wire         cmp_at_bot;
    wire [1:0]   at_cmp;
    counter#(.W(W), .NCHAN(2)) dut_cmp(
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .top(top),
        .cmp({cmp1, cmp0}),
        .count(cmp_count),
        .at_top(cmp_at_top),
        .at_bot(cmp_at_bot),
        .at_cmp(at_cmp)
    );

    task automatic require_cmp;
        input integer         k;
        input         [W-1:0] live;
        input         [W-1:0] sampled;
        reg           [W-1:0] active;
        begin
            active = (expected_count == 0) ? live : sampled;
            `REQUIRE(at_cmp[k] === ((expected_count == active) && enable));
            if (at_cmp[k]) begin
                if (expected_count == 0) cov_cmp_zero = cov_cmp_zero + 1;
                if ((expected_count > 0) && (expected_count < expected_top)) cov_cmp_mid = cov_cmp_mid + 1;
                if ((expected_count > 0) && (expected_count == expected_top)) cov_cmp_top = cov_cmp_top + 1;
            end
            // A mid-period compare value change must not apply until the next period.
            if (enable && (expected_count != 0) && (expected_count == live) && (live != sampled)) begin
                cov_cmp_sample = cov_cmp_sample + 1;
            end
        end
    endtask

    task automatic require_outputs;
        begin
            #1;
            `REQUIRE(count === expected_count);
            `REQUIRE(at_top === ((expected_count == expected_top) && enable));
            `REQUIRE(at_bot === ((expected_count == 0)            && enable));
            `REQUIRE(expected_count <= expected_top);
            `REQUIRE(cmp_count === count);
            `REQUIRE(cmp_at_top === at_top);
            `REQUIRE(cmp_at_bot === at_bot);
            require_cmp(0, cmp0, expected_cmp0);
            require_cmp(1, cmp1, expected_cmp1);
            seen[expected_top][expected_count] = 1'b1;
        end
    endtask

    task automatic clock_and_check;
        reg [W-1:0] next_count;
        reg [W-1:0] next_top;
        reg [W-1:0] next_cmp0;
        reg [W-1:0] next_cmp1;
        reg [W-1:0] active_top;
        begin
            next_count = expected_count;
            next_top   = expected_top;
            next_cmp0  = expected_cmp0;
            next_cmp1  = expected_cmp1;
            active_top = (expected_count == 0) ? top : expected_top;

            if (rst) begin
                next_count = 0;
                next_top   = top;
                next_cmp0  = cmp0;
                next_cmp1  = cmp1;
            end else begin
                // The top and the compare values are sampled when the counter advances from zero.
                if ((expected_count == 0) && enable) begin
                    next_top  = top;
                    next_cmp0 = cmp0;
                    next_cmp1 = cmp1;
                end

                if (enable) begin
                    if (expected_count == active_top) begin
                        next_count = 0;
                    end else begin
                        next_count = expected_count + 1;
                    end
                end
            end

            @(posedge clk);
            expected_count = next_count;
            expected_top   = next_top;
            expected_cmp0  = next_cmp0;
            expected_cmp1  = next_cmp1;
            clock_cycles_checked = clock_cycles_checked + 1;
            require_outputs();
        end
    endtask

    task automatic go_to_state;
        input integer target_top;
        input integer target_count;
        integer cycle;
        begin
            rst    = 1;
            enable = 0;
            top    = target_top;
            cmp0   = target_count;
            cmp1   = target_top;
            clock_and_check();

            rst    = 0;
            enable = 1;
            top    = target_top;
            for (cycle = 0; cycle < target_count; cycle = cycle + 1) begin
                clock_and_check();
            end

            enable = 0;
            `REQUIRE(expected_top == target_top);
            `REQUIRE(expected_count == target_count);
        end
    endtask

    task automatic check_transition_from_state;
        input integer state_top;
        input integer state_count;
        integer reset_case;
        integer enable_case;
        integer input_top;
        begin
            for (reset_case = 0; reset_case < 2; reset_case = reset_case + 1) begin
                for (enable_case = 0; enable_case < 2; enable_case = enable_case + 1) begin
                    for (input_top = 0; input_top < STATE_COUNT; input_top = input_top + 1) begin
                        go_to_state(state_top, state_count);
                        rst    = reset_case;
                        enable = enable_case;
                        top    = input_top;
                        cmp0   = input_top;
                        cmp1   = (input_top * 7 + 3) % STATE_COUNT;
                        clock_and_check();
                        transition_cases_checked = transition_cases_checked + 1;
                    end
                end
            end
        end
    endtask

    task automatic require_full_state_coverage;
        integer coverage_top;
        integer coverage_count;
        integer reachable_states;
        begin
            reachable_states = 0;
            for (coverage_top = 0; coverage_top < STATE_COUNT; coverage_top = coverage_top + 1) begin
                for (coverage_count = 0; coverage_count <= coverage_top; coverage_count = coverage_count + 1) begin
                    `REQUIRE(seen[coverage_top][coverage_count] === 1'b1);
                    reachable_states = reachable_states + 1;
                end
                for (
                    coverage_count = coverage_top + 1;
                    coverage_count < STATE_COUNT;
                    coverage_count = coverage_count + 1
                ) begin
                    `REQUIRE(seen[coverage_top][coverage_count] === 1'b0);
                end
            end

            $display("reachable states: %0d of %0d", reachable_states, STATE_COUNT * STATE_COUNT);
            $display("one-cycle input transitions checked: %0d", transition_cases_checked);
            $display("clock cycles checked: %0d", clock_cycles_checked);
        end
    endtask

    initial begin
        for (init_index = 0; init_index < STATE_COUNT; init_index = init_index + 1) begin
            seen[init_index] = 0;
        end

        for (state_top = 0; state_top < STATE_COUNT; state_top = state_top + 1) begin
            for (state_count = 0; state_count <= state_top; state_count = state_count + 1) begin
                check_transition_from_state(state_top, state_count);
            end
        end

        require_full_state_coverage();

        // Randomized run of the compare channels with occasional resets, top and compare changes.
        for (init_index = 0; init_index < 100000; init_index = init_index + 1) begin
            rst    = rnd(1000) == 0;
            enable = rnd(4) != 0;
            if (rnd(40) == 0) top  = rnd(STATE_COUNT);
            if (rnd(10) == 0) cmp0 = rnd(STATE_COUNT);
            if (rnd(10) == 0) cmp1 = rnd(top + 1);
            clock_and_check();
        end
        $display("compare matches at zero/mid/top: %0d/%0d/%0d; sampled compare held: %0d",
                 cov_cmp_zero, cov_cmp_mid, cov_cmp_top, cov_cmp_sample);
        `REQUIRE(cov_cmp_zero > 0);
        `REQUIRE(cov_cmp_mid > 0);
        `REQUIRE(cov_cmp_top > 0);
        `REQUIRE(cov_cmp_sample > 0);
        $finish;
    end

    integer dump;
    initial begin  // the exhaustive walk plus the randomized run make a large trace, so dumping is opt-in: +dump=1
        if ($value$plusargs("dump=%d", dump) && (dump != 0)) begin
            $dumpfile("counter_tb.vcd");
            $dumpvars();
        end
    end
endmodule

`default_nettype wire
