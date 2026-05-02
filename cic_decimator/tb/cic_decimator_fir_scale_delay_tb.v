/// CIC+FIR wrapper scale and group-delay testbench.
/// Run via `fusesoc run --target=sim_cic_decimator_fir_scale_delay zubax:kulibin:cic_decimator`.

`default_nettype none
`timescale 1ns/1ns

`define REQUIRE(cond) if(!(cond)) $fatal

module cic_decimator_fir_scale_delay_tb;
    reg clk = 0;
    always #5 clk = !clk;

    localparam RCIC = 4;
    localparam NCIC = 2;
    localparam NFIR = 1;
    localparam WK = 16;
    localparam SIGNED_WIN = 3;
    localparam SIGNED_WOUT = 7;
    localparam BIT_WIN = 1;
    localparam BIT_WOUT = 5;
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
    wire signed_out_valid;
    wire signed [SIGNED_WOUT-1:0] signed_out_data;

    reg bit_in_valid = 0;
    reg signed [BIT_WIN-1:0] bit_in_data = 0;
    wire bit_out_valid;
    wire signed [BIT_WOUT-1:0] bit_out_data;

    cic_decimator_fir#(
        .WIN(SIGNED_WIN),
        .RCIC(RCIC),
        .NCIC(NCIC),
        .NFIR(NFIR),
        .WOUT(SIGNED_WOUT),
        .WK(WK),
        .KERNEL("half2_q1_15.fir.memb")
    ) dut_signed (
        .clk(clk),
        .rst(rst),
        .in_valid(signed_in_valid),
        .in_data(signed_in_data),
        .out_valid(signed_out_valid),
        .out_data(signed_out_data)
    );

    cic_decimator_fir#(
        .WIN(BIT_WIN),
        .RCIC(RCIC),
        .NCIC(NCIC),
        .NFIR(NFIR),
        .WOUT(BIT_WOUT),
        .WK(WK),
        .KERNEL("half2_q1_15.fir.memb")
    ) dut_bit (
        .clk(clk),
        .rst(rst),
        .in_valid(bit_in_valid),
        .in_data(bit_in_data),
        .out_valid(bit_out_valid),
        .out_data(bit_out_data)
    );

    integer cycle = 0;
    integer out_count = 0;
    integer stable_count = 0;
    integer coeff_index = 0;
    integer impulse_sum = 0;
    integer impulse_moment = 0;

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

    function automatic integer expected_impulse_sample;
        input integer index;
        integer current_cic;
        integer previous_cic;
        begin
            current_cic = cic_coeff(index);
            previous_cic = cic_coeff(index - RCIC);
            expected_impulse_sample = (current_cic + previous_cic) / 2;
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

    task automatic run_signed_constant;
        input signed [SIGNED_WIN-1:0] sample;
        input signed [SIGNED_WOUT-1:0] expected;
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

                if (signed_out_valid) begin
                    out_count = out_count + 1;
                    if (out_count > (NCIC + NFIR + 1)) begin
                        `REQUIRE(signed_out_data == expected);
                        stable_count = stable_count + 1;
                    end
                end
                `REQUIRE(!bit_out_valid);

                @(negedge clk);
            end

            signed_in_valid <= 1'b0;
            signed_in_data <= 0;
            `REQUIRE(stable_count > 0);
        end
    endtask

    task automatic run_bit_constant;
        input sample;
        input signed [BIT_WOUT-1:0] expected;
        begin
            reset_case;
            out_count = 0;
            stable_count = 0;

            for (cycle = 0; cycle < RUN_CYCLES; cycle = cycle + 1) begin
                signed_in_valid <= 1'b0;
                signed_in_data <= 0;
                bit_in_valid <= 1'b1;
                bit_in_data <= sample;

                @(posedge clk);
                #1;

                `REQUIRE(!signed_out_valid);
                if (bit_out_valid) begin
                    out_count = out_count + 1;
                    if (out_count > (NCIC + NFIR + 1)) begin
                        `REQUIRE(bit_out_data == expected);
                        stable_count = stable_count + 1;
                    end
                end

                @(negedge clk);
            end

            bit_in_valid <= 1'b0;
            bit_in_data <= 0;
            `REQUIRE(stable_count > 0);
        end
    endtask

    task automatic run_impulse_case;
        begin
            reset_case;
            out_count = 0;
            impulse_sum = 0;
            impulse_moment = 0;

            for (cycle = 0; cycle < IMPULSE_CYCLES; cycle = cycle + 1) begin
                signed_in_valid <= 1'b1;
                signed_in_data <= (cycle == 0) ? 3'sd1 : 3'sd0;
                bit_in_valid <= 1'b0;
                bit_in_data <= 0;

                @(posedge clk);
                #1;

                if (signed_out_valid) begin
                    coeff_index = RESPONSE_PHASE + out_count * RCIC;
                    `REQUIRE(signed_out_data == expected_impulse_sample(coeff_index));
                    impulse_sum = impulse_sum + signed_out_data;
                    impulse_moment = impulse_moment + signed_out_data * coeff_index;
                    $display("y[%0d] = %0d", coeff_index, signed_out_data);
                    out_count = out_count + 1;
                end
                `REQUIRE(!bit_out_valid);

                @(negedge clk);
            end

            signed_in_valid <= 1'b0;
            signed_in_data <= 0;

            repeat (20) begin
                @(posedge clk);
                #1;
                if (signed_out_valid) begin
                    coeff_index = RESPONSE_PHASE + out_count * RCIC;
                    `REQUIRE(signed_out_data == expected_impulse_sample(coeff_index));
                    impulse_sum = impulse_sum + signed_out_data;
                    impulse_moment = impulse_moment + signed_out_data * coeff_index;
                    $display("y[%0d] = %0d", coeff_index, signed_out_data);
                    out_count = out_count + 1;
                end
                `REQUIRE(!bit_out_valid);
                @(negedge clk);
            end

            `REQUIRE(out_count == IMPULSE_PERIODS);
            `REQUIRE(impulse_sum == RESPONSE_GAIN);
            `REQUIRE((2 * impulse_moment) == (impulse_sum * TOTAL_DELAY_NUMERATOR));
        end
    endtask

    initial begin
        `REQUIRE(RCIC >= (NFIR + 2));

        run_signed_constant(3'sd3,   7'sd48);
        run_signed_constant(-3'sd4, -7'sd64);
        run_bit_constant(1'b0,  5'sd15);
        run_bit_constant(1'b1, -5'sd16);
        run_impulse_case;

        $finish;
    end

    initial begin
        $dumpfile("cic_decimator_fir_scale_delay_tb.vcd");
        $dumpvars();
    end
endmodule
