// iverilog -Wall -Wno-timescale -y. deadtime_complementer_var_tb.v && vvp a.out

`timescale 1ns/1ps
`default_nettype none

`define REQUIRE(cond) if (!(cond)) $fatal


module deadtime_complementer_var_tb;
    localparam integer DTW = 2;
    localparam integer DT_COUNT = 1 << DTW;
    localparam integer STATE_BITS = DTW + 4;
    localparam integer STATE_COUNT = 1 << STATE_BITS;

    localparam integer ACTIVE_BIT = DTW;
    localparam integer TARGET_BIT = DTW + 1;
    localparam integer NEG_BIT = DTW + 2;
    localparam integer POS_BIT = DTW + 3;

    localparam [STATE_BITS-1:0] RESET_STATE = {STATE_BITS{1'b0}};

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;  // 100 MHz

    reg in = 1'b0;
    reg [DTW-1:0] deadtime = {DTW{1'b0}};

    wire pos;
    wire neg;
    deadtime_complementer_var #(DTW) dut (
        .clk(clk),
        .rst(rst),
        .in(in),
        .deadtime(deadtime),
        .pos(pos),
        .neg(neg)
    );

    wire [DT_COUNT-1:0] pos_var_fixed;
    wire [DT_COUNT-1:0] neg_var_fixed;
    wire [DT_COUNT-1:0] pos_const_fixed;
    wire [DT_COUNT-1:0] neg_const_fixed;

    deadtime_complementer_var #(DTW) fixed_var_dt0 (
        .clk(clk),
        .rst(rst),
        .in(in),
        .deadtime(2'd0),
        .pos(pos_var_fixed[0]),
        .neg(neg_var_fixed[0])
    );
    deadtime_complementer_var #(DTW) fixed_var_dt1 (
        .clk(clk),
        .rst(rst),
        .in(in),
        .deadtime(2'd1),
        .pos(pos_var_fixed[1]),
        .neg(neg_var_fixed[1])
    );
    deadtime_complementer_var #(DTW) fixed_var_dt2 (
        .clk(clk),
        .rst(rst),
        .in(in),
        .deadtime(2'd2),
        .pos(pos_var_fixed[2]),
        .neg(neg_var_fixed[2])
    );
    deadtime_complementer_var #(DTW) fixed_var_dt3 (
        .clk(clk),
        .rst(rst),
        .in(in),
        .deadtime(2'd3),
        .pos(pos_var_fixed[3]),
        .neg(neg_var_fixed[3])
    );

    deadtime_complementer #(0) fixed_const_dt0 (
        .clk(clk),
        .rst(rst),
        .in(in),
        .pos(pos_const_fixed[0]),
        .neg(neg_const_fixed[0])
    );
    deadtime_complementer #(1) fixed_const_dt1 (
        .clk(clk),
        .rst(rst),
        .in(in),
        .pos(pos_const_fixed[1]),
        .neg(neg_const_fixed[1])
    );
    deadtime_complementer #(2) fixed_const_dt2 (
        .clk(clk),
        .rst(rst),
        .in(in),
        .pos(pos_const_fixed[2]),
        .neg(neg_const_fixed[2])
    );
    deadtime_complementer #(3) fixed_const_dt3 (
        .clk(clk),
        .rst(rst),
        .in(in),
        .pos(pos_const_fixed[3]),
        .neg(neg_const_fixed[3])
    );

    reg reachable [0:STATE_COUNT-1];

    function automatic [STATE_BITS-1:0] pack_state;
        input pos_i;
        input neg_i;
        input target_i;
        input active_i;
        input [DTW-1:0] t_i;
        begin
            pack_state = {pos_i, neg_i, target_i, active_i, t_i};
        end
    endfunction

    function automatic [STATE_BITS-1:0] model_next;
        input [STATE_BITS-1:0] state_i;
        input rst_i;
        input in_i;
        input [DTW-1:0] deadtime_i;

        reg pos_v;
        reg neg_v;
        reg target_v;
        reg active_v;
        reg [DTW-1:0] t_v;
        begin
            pos_v = state_i[POS_BIT];
            neg_v = state_i[NEG_BIT];
            target_v = state_i[TARGET_BIT];
            active_v = state_i[ACTIVE_BIT];
            t_v = state_i[DTW-1:0];

            if (rst_i) begin
                pos_v = 1'b0;
                neg_v = 1'b0;
                target_v = 1'b0;
                active_v = 1'b0;
                t_v = {DTW{1'b0}};
            end else if (!active_v) begin
                if (in_i != target_v) begin
                    target_v = in_i;
                    if (deadtime_i == {DTW{1'b0}}) begin
                        pos_v = in_i;
                        neg_v = ~in_i;
                        active_v = 1'b0;
                        t_v = {DTW{1'b0}};
                    end else begin
                        pos_v = 1'b0;
                        neg_v = 1'b0;
                        active_v = 1'b1;
                        t_v = deadtime_i - 1'b1;
                    end
                end else begin
                    pos_v = target_v;
                    neg_v = ~target_v;
                    active_v = 1'b0;
                    t_v = {DTW{1'b0}};
                end
            end else begin
                if (in_i != target_v) begin
                    target_v = in_i;
                    if (deadtime_i == {DTW{1'b0}}) begin
                        pos_v = in_i;
                        neg_v = ~in_i;
                        active_v = 1'b0;
                        t_v = {DTW{1'b0}};
                    end else begin
                        pos_v = 1'b0;
                        neg_v = 1'b0;
                        active_v = 1'b1;
                        t_v = deadtime_i - 1'b1;
                    end
                end else if (t_v != 0) begin
                    pos_v = 1'b0;
                    neg_v = 1'b0;
                    active_v = 1'b1;
                    t_v = t_v - 1'b1;
                end else begin
                    pos_v = target_v;
                    neg_v = ~target_v;
                    active_v = 1'b0;
                    t_v = {DTW{1'b0}};
                end
            end

            model_next = pack_state(pos_v, neg_v, target_v, active_v, t_v);
        end
    endfunction

    task automatic set_dut_state;
        input [STATE_BITS-1:0] state_i;
        begin
            dut.pos = state_i[POS_BIT];
            dut.neg = state_i[NEG_BIT];
            dut.target = state_i[TARGET_BIT];
            dut.active = state_i[ACTIVE_BIT];
            dut.t = state_i[DTW-1:0];
        end
    endtask

    task automatic require_dut_state;
        input [STATE_BITS-1:0] expected_i;
        begin
            `REQUIRE(pos === expected_i[POS_BIT]);
            `REQUIRE(neg === expected_i[NEG_BIT]);
            `REQUIRE(dut.target === expected_i[TARGET_BIT]);
            `REQUIRE(dut.active === expected_i[ACTIVE_BIT]);
            `REQUIRE(dut.t === expected_i[DTW-1:0]);
            `REQUIRE((pos && neg) === 1'b0);
        end
    endtask

    task automatic enumerate_reachable;
        integer state_idx;
        integer in_idx;
        integer deadtime_idx;
        integer changed;
        integer reachable_count;
        reg in_value;
        reg [DTW-1:0] deadtime_value;
        reg [STATE_BITS-1:0] state_value;
        reg [STATE_BITS-1:0] next_value;
        begin
            for (state_idx = 0; state_idx < STATE_COUNT; state_idx = state_idx + 1) begin
                reachable[state_idx] = 1'b0;
            end
            reachable[RESET_STATE] = 1'b1;

            changed = 1;
            while (changed != 0) begin
                changed = 0;
                for (state_idx = 0; state_idx < STATE_COUNT; state_idx = state_idx + 1) begin
                    if (reachable[state_idx]) begin
                        state_value = state_idx;
                        for (in_idx = 0; in_idx < 2; in_idx = in_idx + 1) begin
                            in_value = in_idx[0];
                            for (deadtime_idx = 0; deadtime_idx < DT_COUNT; deadtime_idx = deadtime_idx + 1) begin
                                deadtime_value = deadtime_idx[DTW-1:0];
                                next_value = model_next(state_value, 1'b0, in_value, deadtime_value);
                                `REQUIRE((next_value[POS_BIT] && next_value[NEG_BIT]) === 1'b0);
                                if (!reachable[next_value]) begin
                                    reachable[next_value] = 1'b1;
                                    changed = 1;
                                end
                            end
                        end
                    end
                end
            end

            reachable_count = 0;
            for (state_idx = 0; state_idx < STATE_COUNT; state_idx = state_idx + 1) begin
                if (reachable[state_idx]) begin
                    reachable_count = reachable_count + 1;
                end
            end
            $display("reachable states: %0d of %0d", reachable_count, STATE_COUNT);
            `REQUIRE(reachable_count > 0);
        end
    endtask

    task automatic verify_reachable_transitions;
        integer state_idx;
        integer in_idx;
        integer deadtime_idx;
        reg in_value;
        reg [DTW-1:0] deadtime_value;
        reg [STATE_BITS-1:0] state_value;
        reg [STATE_BITS-1:0] expected_value;
        begin
            for (state_idx = 0; state_idx < STATE_COUNT; state_idx = state_idx + 1) begin
                if (reachable[state_idx]) begin
                    state_value = state_idx;
                    for (in_idx = 0; in_idx < 2; in_idx = in_idx + 1) begin
                        in_value = in_idx[0];
                        for (deadtime_idx = 0; deadtime_idx < DT_COUNT; deadtime_idx = deadtime_idx + 1) begin
                            deadtime_value = deadtime_idx[DTW-1:0];
                            expected_value = model_next(state_value, 1'b0, in_value, deadtime_value);

                            @(negedge clk);
                            rst = 1'b0;
                            in = in_value;
                            deadtime = deadtime_value;
                            set_dut_state(state_value);

                            @(posedge clk);
                            #1 require_dut_state(expected_value);
                        end
                    end
                end
            end
        end
    endtask

    task automatic verify_reset_recovery;
        integer state_idx;
        reg [STATE_BITS-1:0] state_value;
        begin
            for (state_idx = 0; state_idx < STATE_COUNT; state_idx = state_idx + 1) begin
                if (reachable[state_idx]) begin
                    state_value = state_idx;

                    @(negedge clk);
                    rst = 1'b1;
                    in = state_idx[0];
                    deadtime = state_idx[DTW-1:0];
                    set_dut_state(state_value);

                    @(posedge clk);
                    #1 require_dut_state(RESET_STATE);
                end
            end
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic verify_fixed_compatibility;
        integer sequence_idx;
        integer bit_idx;
        begin
            for (sequence_idx = 0; sequence_idx < 256; sequence_idx = sequence_idx + 1) begin
                @(negedge clk);
                rst = 1'b1;
                in = 1'b0;
                deadtime = {DTW{1'b0}};

                @(negedge clk);
                rst = 1'b0;

                for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                    @(negedge clk);
                    in = sequence_idx[bit_idx];
                end
            end
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (!rst) begin
            `REQUIRE((pos && neg) === 1'b0);
            `REQUIRE((|(pos_var_fixed & neg_var_fixed)) === 1'b0);
            `REQUIRE(pos_var_fixed === pos_const_fixed);
            `REQUIRE(neg_var_fixed === neg_const_fixed);
        end
    end

    initial begin
        $dumpfile("deadtime_complementer_var_tb.vcd");
        $dumpvars();

        enumerate_reachable();

        rst = 1'b1;
        in = 1'b0;
        deadtime = {DTW{1'b0}};
        repeat (2) @(negedge clk);
        #1 require_dut_state(RESET_STATE);

        verify_reachable_transitions();
        verify_reset_recovery();
        verify_fixed_compatibility();

        $finish;
    end
endmodule
