// iverilog -Wall -Wno-timescale -y. up_down_pwm_tb.v && vvp a.out

`timescale 1ns/1ns
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal

module up_down_pwm_tb;
    localparam W = 8;
    localparam SHADOW_RELOAD_TOP = 1;
    localparam SHADOW_RELOAD_BOT = 2;

    reg clk = 0;
    always #1 clk = !clk;

    reg rst = 1;
    reg [W-1:0] top     = 4;
    reg [W-1:0] compare = 1;

    wire at_top_both;
    wire at_bot_both;
    wire out_both;
    up_down_pwm#(W) pwm_both (
        .clk(clk),
        .rst(rst),
        .top(top),
        .compare(compare),
        .at_top(at_top_both),
        .at_bot(at_bot_both),
        .out(out_both)
    );

    wire at_top_top;
    wire at_bot_top;
    wire out_top;
    up_down_pwm #(.W(W), .SHADOW_RELOAD(SHADOW_RELOAD_TOP)) pwm_top (
        .clk(clk),
        .rst(rst),
        .top(top),
        .compare(compare),
        .at_top(at_top_top),
        .at_bot(at_bot_top),
        .out(out_top)
    );

    wire at_top_bot;
    wire at_bot_bot;
    wire out_bot;
    up_down_pwm #(.W(W), .SHADOW_RELOAD(SHADOW_RELOAD_BOT)) pwm_bot (
        .clk(clk),
        .rst(rst),
        .top(top),
        .compare(compare),
        .at_top(at_top_bot),
        .at_bot(at_bot_bot),
        .out(out_bot)
    );

    reg [W-1:0] top_wave     = 4;
    reg [W-1:0] compare_wave = 0;
    wire at_top_wave;
    wire at_bot_wave;
    wire out_wave;
    up_down_pwm#(W) pwm_wave (
        .clk(clk),
        .rst(rst),
        .top(top_wave),
        .compare(compare_wave),
        .at_top(at_top_wave),
        .at_bot(at_bot_wave),
        .out(out_wave)
    );

    // Carrier strobe semantics, on an instance with its own reset so the stimulus below is undisturbed.
    // at_top and at_bot must mark the extrema of a running carrier only. The counter and the latched top are both
    // zero under reset, which without qualification makes at_top a level for the whole of reset and emits one more
    // spurious pulse at release, before the carrier has started -- an edge-counting consumer would miscount at
    // every reset.
    localparam [W-1:0] STROBE_TOP = 6;
    reg rst_strobe = 1;
    wire at_top_strobe;
    wire at_bot_strobe;
    up_down_pwm#(W) pwm_strobe (
        .clk(clk),
        .rst(rst_strobe),
        .top(STROBE_TOP),
        .compare({W{1'b0}}),
        .at_top(at_top_strobe),
        .at_bot(at_bot_strobe),
        .out()
    );

    task automatic check_strobes_mark_a_running_carrier;
        integer idx;
        integer first_top;
        integer first_bot;
        integer width;
        reg expect_top;
        reg expect_bot;
        begin
            width = 0;
            rst_strobe = 1;
            repeat (2 * STROBE_TOP) @(negedge clk);
            // Held in reset, neither strobe may assert at all -- not even as a level.
            repeat (2 * STROBE_TOP) begin
                `REQUIRE(at_top_strobe === 1'b0);
                `REQUIRE(at_bot_strobe === 1'b0);
                @(negedge clk);
            end

            // Every cycle from release is checked against where the strobes are required to be, rather than
            // scanning for the first one and measuring intervals from there: a scan cannot tell a missing strobe
            // from a late one, and in particular a carrier that simply never emitted its first bottom would pass.
            // The carrier needs one cycle to latch its top, then a full up-ramp, so the extrema fall at
            // STROBE_TOP, then every STROBE_TOP thereafter, alternating top/bottom, one cycle wide each.
            rst_strobe = 0;
            // The release cycle itself, which the negedge scan below cannot see: it starts one posedge later, by
            // which time top_r has loaded and the raw extremum has fallen. Qualifying with !rst instead of
            // top_r != 0 emits its spurious strobe entirely inside this window, so without this check that
            // wrong-but-plausible variant passes the whole bench. #0 settles the continuous assignments first.
            #0;
            `REQUIRE(at_top_strobe === 1'b0);
            `REQUIRE(at_bot_strobe === 1'b0);

            first_top = STROBE_TOP;                  // index of the first top after release
            first_bot = first_top + STROBE_TOP;      // and of the first bottom
            for (idx = 0; idx < 5 * STROBE_TOP; idx = idx + 1) begin
                @(negedge clk);
                expect_top = (idx >= first_top) && (((idx - first_top) % (2 * STROBE_TOP)) == 0);
                expect_bot = (idx >= first_bot) && (((idx - first_bot) % (2 * STROBE_TOP)) == 0);
                `REQUIRE(at_top_strobe === expect_top);
                `REQUIRE(at_bot_strobe === expect_bot);
                if (at_top_strobe === 1'b1) width = width + 1;
            end
            // Sanity on the check itself: it must have seen actual strobes, not merely agreed on silence.
            `REQUIRE(width >= 2);
        end
    endtask

    // Multi-channel equivalence: one NCHAN instance against that many independent single-channel instances driven
    // with the same top and the same per-channel compare. Sharing one counter must not make the channels interact,
    // so every channel must track its own reference cycle for cycle. The references stand in for the whole carrier
    // too: were NCHAN to perturb the counter, every channel at once would drift off its reference.
    localparam NCHAN = 3;
    reg [W-1:0]       top_multi     = 4;
    reg [NCHAN*W-1:0] compare_multi = 0;

    wire [NCHAN-1:0] out_multi;
    up_down_pwm #(.W(W), .NCHAN(NCHAN)) pwm_multi (
        .clk(clk),
        .rst(rst),
        .top(top_multi),
        .compare(compare_multi),
        .at_top(),
        .at_bot(),
        .out(out_multi)
    );

    wire [NCHAN-1:0] out_ref;
    genvar g;
    generate
        for (g = 0; g < NCHAN; g = g + 1) begin : g_ref
            up_down_pwm#(W) pwm_ref (
                .clk(clk),
                .rst(rst),
                .top(top_multi),
                .compare(compare_multi[W*g +: W]),
                .at_top(),
                .at_bot(),
                .out(out_ref[g])
            );
        end
    endgenerate

    // Continuous equivalence check, plus coverage so that a vacuous (never-toggling) run cannot pass. Once armed it
    // stays armed to the end of the run, so the later shadow-hold and reset stimulus is covered by it as well.
    reg              check_multi    = 0;
    reg  [NCHAN-1:0] out_multi_prev = 0;
    integer multi_cycles_checked = 0;
    integer cov_multi_toggle [0:NCHAN-1];

    // Each process keeps its own loop variable: a shared one would be a race between them.
    initial begin : cov_multi_init
        integer chan;
        for (chan = 0; chan < NCHAN; chan = chan + 1) begin
            cov_multi_toggle[chan] = 0;
        end
    end

    always @(negedge clk) begin : multi_equivalence_check
        integer chan;
        if (check_multi) begin
            for (chan = 0; chan < NCHAN; chan = chan + 1) begin
                `REQUIRE(out_multi[chan] === out_ref[chan]);
                if (out_multi[chan] !== out_multi_prev[chan]) begin
                    cov_multi_toggle[chan] = cov_multi_toggle[chan] + 1;
                end
            end
            multi_cycles_checked = multi_cycles_checked + 1;
        end
        out_multi_prev <= out_multi;
    end

    // Applies the shared top and the per-channel compares, then holds them for the requested number of cycles.
    // The compares are named one by one rather than packed by the caller, so a call site reads as a per-channel duty.
    task automatic drive_multi;
        input [W-1:0] top_value;
        input [W-1:0] value_a;
        input [W-1:0] value_b;
        input [W-1:0] value_c;
        input integer cycles;
        integer idx;
        begin
            top_multi     = top_value;
            compare_multi = {value_c, value_b, value_a};
            for (idx = 0; idx < cycles; idx = idx + 1) begin
                @(negedge clk);
            end
        end
    endtask

    // Shadow-hold coverage: a compare written mid-period must stay invisible on the output until the reload instant,
    // which is the whole point of the shadow register; checking compare_r alone would not notice the output bypassing
    // it. Bottom-only reload gives a hold window spanning a full period, so it covers the top, where a forced-high
    // duty would otherwise be masked. The reference keeps the old compare and so embodies the duty the DUT must go on
    // showing, whatever its shape.
    reg [W-1:0] top_hold         = 8;
    reg [W-1:0] top_hold_ref     = 8;
    reg [W-1:0] compare_hold     = 0;
    reg [W-1:0] compare_hold_ref = 0;

    wire out_hold;
    wire at_bot_hold;
    up_down_pwm #(.W(W), .SHADOW_RELOAD(SHADOW_RELOAD_BOT)) pwm_hold (
        .clk(clk),
        .rst(rst),
        .top(top_hold),
        .compare(compare_hold),
        .at_top(),
        .at_bot(at_bot_hold),
        .out(out_hold)
    );

    wire out_hold_ref;
    up_down_pwm #(.W(W), .SHADOW_RELOAD(SHADOW_RELOAD_BOT)) pwm_hold_ref (
        .clk(clk),
        .rst(rst),
        .top(top_hold_ref),
        .compare(compare_hold_ref),
        .at_top(),
        .at_bot(),
        .out(out_hold_ref)
    );

    task automatic check_shadow_holds_output;
        input [W-1:0] old_compare;
        input [W-1:0] new_compare;
        integer guard;
        integer held;
        begin
            // Settle both instances on the old compare, so they run in lockstep before the write.
            compare_hold     = old_compare;
            compare_hold_ref = old_compare;
            top_hold_ref     = top_hold;
            guard = 0;
            while ((pwm_hold.compare_r !== old_compare) || (pwm_hold_ref.compare_r !== old_compare)) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end
            repeat (2 * top_hold) @(negedge clk);

            // Align just past a bottom reload edge, so the write misses it, then write without awaiting the latch.
            guard = 0;
            while (at_bot_hold !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end
            @(negedge clk);
            compare_hold = new_compare;
            `REQUIRE(pwm_hold.compare_r === old_compare);

            held  = 0;
            guard = 0;
            while (pwm_hold.compare_r === old_compare) begin
                `REQUIRE(out_hold === out_hold_ref);
                held  = held + 1;
                guard = guard + 1;
                `REQUIRE(guard < 128);
                @(negedge clk);
            end
            `REQUIRE(held > top_hold);  // the window must reach the top, not stop short of it
        end
    endtask

    // The same deferral must hold for a new top. A channel at 100% duty (compare_r == top_r) is the exposed case:
    // should the forced-high test consult the unlatched top, the channel falls through to the counter-match branch
    // and drops low mid-period, which is exactly the glitch the shadow register exists to prevent.
    // Runs last among the shadow checks: the reference keeps the old top, so afterwards the two instances no longer
    // share a carrier phase and cannot be compared again.
    task automatic check_shadow_holds_output_on_top_change;
        input [W-1:0] old_top;
        input [W-1:0] new_top;
        integer guard;
        integer held;
        begin
            // Settle both at 100% duty, which is what the forced-high branch drives.
            top_hold         = old_top;
            top_hold_ref     = old_top;
            compare_hold     = old_top;
            compare_hold_ref = old_top;
            guard = 0;
            while ((pwm_hold.top_r     !== old_top) || (pwm_hold.compare_r     !== old_top) ||
                   (pwm_hold_ref.top_r !== old_top) || (pwm_hold_ref.compare_r !== old_top)) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end
            repeat (2 * old_top) @(negedge clk);
            `REQUIRE(out_hold === 1'b1);  // 100% duty, so the output is held high

            // Align just past a bottom reload edge, so the write misses it, then write without awaiting the latch.
            guard = 0;
            while (at_bot_hold !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end
            @(negedge clk);
            top_hold = new_top;  // the reference keeps the old top
            `REQUIRE(pwm_hold.top_r === old_top);

            held  = 0;
            guard = 0;
            while (pwm_hold.top_r === old_top) begin
                `REQUIRE(out_hold === out_hold_ref);
                held  = held + 1;
                guard = guard + 1;
                `REQUIRE(guard < 128);
                @(negedge clk);
            end
            `REQUIRE(held > old_top);  // the window must reach the old top, where the fall-through would show
        end
    endtask

    task automatic wait_top_latched;
        integer guard;
        begin
            guard = 0;
            while (at_top_both !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 64);
            end
            @(negedge clk);
        end
    endtask

    task automatic wait_bot_latched;
        integer guard;
        begin
            guard = 0;
            while (at_bot_both !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 64);
            end
            @(negedge clk);
        end
    endtask

    task automatic wait_bot_latched_bot;
        integer guard;
        begin
            guard = 0;
            while (at_bot_bot !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 64);
            end
            @(negedge clk);
        end
    endtask

    task automatic load_wave;
        input [W-1:0] top_value;
        input [W-1:0] compare_value;
        integer guard;
        begin
            top_wave     = top_value;
            compare_wave = compare_value;

            guard = 0;
            while ((pwm_wave.top_r !== top_value) || (pwm_wave.compare_r !== compare_value)) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end
        end
    endtask

    task automatic wait_wave_bot_edge;
        integer guard;
        begin
            guard = 0;
            while (at_bot_wave === 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end

            while (at_bot_wave !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                `REQUIRE(guard < 128);
            end
        end
    endtask

    task automatic check_wave_period;
        input [W-1:0] top_value;
        input [W-1:0] compare_value;
        input integer expected_high_count;
        integer guard;
        integer high_count;
        integer period;
        begin
            load_wave(top_value, compare_value);
            wait_wave_bot_edge();

            period = 2 * top_value;
            high_count = 0;
            for (guard = 0; guard < period; guard = guard + 1) begin
                if (out_wave === 1'b1) begin
                    high_count = high_count + 1;
                end
                @(negedge clk);
            end

            `REQUIRE(at_bot_wave === 1'b1);
            `REQUIRE(high_count == expected_high_count);
        end
    endtask

    task automatic check_wave_hold;
        input [W-1:0] top_value;
        input [W-1:0] compare_value;
        input expected_out;
        input integer cycles;
        integer idx;
        begin
            load_wave(top_value, compare_value);
            for (idx = 0; idx < cycles; idx = idx + 1) begin
                @(negedge clk);
                `REQUIRE(out_wave === expected_out);
            end
        end
    endtask

    initial begin
        $dumpfile("up_down_pwm_tb.vcd");
        $dumpvars();

        repeat (2) @(negedge clk);
        `REQUIRE(out_multi === {NCHAN{1'b0}});  // every channel output clears under reset
        rst = 0;
        repeat (2) @(negedge clk);

        `REQUIRE(pwm_both.top_r === top);
        `REQUIRE(pwm_top.top_r === top);
        `REQUIRE(pwm_bot.top_r === top);
        `REQUIRE(pwm_both.compare_r === compare);
        `REQUIRE(pwm_top.compare_r === compare);
        `REQUIRE(pwm_bot.compare_r === compare);

        wait_bot_latched();
        compare = 2;
        `REQUIRE(pwm_both.compare_r === 1);
        `REQUIRE(pwm_top.compare_r === 1);
        `REQUIRE(pwm_bot.compare_r === 1);

        wait_top_latched();
        `REQUIRE(pwm_both.compare_r === 2);
        `REQUIRE(pwm_top.compare_r === 2);
        `REQUIRE(pwm_bot.compare_r === 1);

        wait_bot_latched();
        `REQUIRE(pwm_both.compare_r === 2);
        `REQUIRE(pwm_top.compare_r === 2);
        `REQUIRE(pwm_bot.compare_r === 2);

        wait_top_latched();
        compare = 3;
        `REQUIRE(pwm_both.compare_r === 2);
        `REQUIRE(pwm_top.compare_r === 2);
        `REQUIRE(pwm_bot.compare_r === 2);

        wait_bot_latched();
        `REQUIRE(pwm_both.compare_r === 3);
        `REQUIRE(pwm_top.compare_r === 2);
        `REQUIRE(pwm_bot.compare_r === 3);

        wait_top_latched();
        `REQUIRE(pwm_both.compare_r === 3);
        `REQUIRE(pwm_top.compare_r === 3);
        `REQUIRE(pwm_bot.compare_r === 3);

        top = 0;
        wait_bot_latched_bot();
        `REQUIRE(pwm_bot.top_r === 0);

        top = 5;
        repeat (3) @(negedge clk);
        `REQUIRE(pwm_bot.top_r === 5);
        `REQUIRE(pwm_bot.counter !== 0);

        wait_bot_latched_bot();
        `REQUIRE(pwm_bot.top_r === 5);

        check_wave_period(4, 0, 0);
        check_wave_period(4, 1, 2);
        check_wave_period(4, 3, 6);
        check_wave_period(4, 4, 8);

        check_wave_period(4, 0, 0);
        check_wave_hold(4, 6, 1'b0, 16);
        check_wave_period(4, 4, 8);
        check_wave_hold(4, 6, 1'b1, 16);
        check_wave_hold(0, 3, 1'b1, 8);

        // Multi-channel stimulus. Every channel hits each output branch, and each is moved while the others hold,
        // so any cross-channel leakage would show up as a divergence from that channel's own reference.
        check_multi = 1;
        drive_multi(4, 0, 2, 4, 24);  // forced low, mid-range, forced high, simultaneously
        drive_multi(4, 4, 0, 2, 24);  // rotate the roles
        drive_multi(4, 2, 4, 0, 24);
        drive_multi(4, 1, 3, 2, 25);  // all mid-range, all distinct; odd length breaks the carrier phase lock
        drive_multi(4, 3, 3, 3, 24);  // all identical
        drive_multi(4, 3, 3, 1, 24);  // move only channel c
        drive_multi(4, 3, 1, 1, 24);  // move only channel b
        drive_multi(4, 1, 1, 1, 24);  // move only channel a
        drive_multi(6, 1, 1, 1, 32);  // change the shared top, compares held
        drive_multi(0, 1, 2, 3, 16);  // degenerate top
        drive_multi(5, 5, 0, 3, 32);
        `REQUIRE(multi_cycles_checked > 250);
        begin : cov_multi_check
            integer chan;
            for (chan = 0; chan < NCHAN; chan = chan + 1) begin
                `REQUIRE(cov_multi_toggle[chan] > 30);
            end
        end

        // A mid-period compare write must stay invisible on the output until the reload instant.
        check_shadow_holds_output(2, 6);  // a latched mid-range duty must not jump to the new value
        check_shadow_holds_output(6, 1);  // nor to a lower one
        check_shadow_holds_output(8, 2);  // a latched forced-high duty (compare == top) must not drop
        check_shadow_holds_output(0, 4);  // a latched forced-low duty (compare == 0) must not rise
        check_shadow_holds_output_on_top_change(8, 4);  // a new top must not disturb a channel at 100% duty either

        check_strobes_mark_a_running_carrier();

        // Reset must clear every channel, not just channel 0.
        drive_multi(4, 1, 3, 4, 8);
        `REQUIRE(out_multi[NCHAN-1] === 1'b1);  // the top channel sits at the top, hence high, going in
        rst = 1;
        repeat (2) @(negedge clk);
        `REQUIRE(out_multi === {NCHAN{1'b0}});

        $finish;
    end
endmodule
