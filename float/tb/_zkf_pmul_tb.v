// Exactness bench for the shared pipelined multiply _zkf_pmul: proves p == a*b (with per-operand signedness) for
// every STAGE_PRODUCT in {0,1,2,3}, both signedness flags, and several (WA,WB) including the exact sincos widths.
// Inputs are held stable and the result sampled after the deepest pipeline settles, so one check covers any latency.

`timescale 1ns / 1ps
`default_nettype none

// One device-under-test plus its independent 128-bit signed reference; `bad` is high whenever the DUT's low WA+WB
// product bits disagree with a*b. Sign/zero-extension of each operand follows its A_SIGNED/B_SIGNED flag.
module pmul_check #(
    parameter integer WA = 8, parameter integer WB = 8,
    parameter integer A_SIGNED = 1, parameter integer B_SIGNED = 1, parameter integer SP = 0,
    parameter integer WMULTIPLIER = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [63:0] a_drv,
    input  wire [63:0] b_drv,
    output wire        bad
);
    wire [WA+WB-1:0] p;
    _zkf_pmul #(.WA(WA), .WB(WB), .A_SIGNED(A_SIGNED), .B_SIGNED(B_SIGNED), .WSB(1),
                .STAGE_PRODUCT(SP), .WMULTIPLIER(WMULTIPLIER)) dut (
        .clk(clk), .rst(rst), .in_valid(1'b0), .sb_in(1'b0),
        .a(a_drv[WA-1:0]), .b(b_drv[WB-1:0]), .out_valid(), .sb_out(), .p(p));
    wire signed [127:0] ar = (A_SIGNED != 0) ? $signed({{(128-WA){a_drv[WA-1]}}, a_drv[WA-1:0]})
                                             : $signed({{(128-WA){1'b0}}, a_drv[WA-1:0]});
    wire signed [127:0] br = (B_SIGNED != 0) ? $signed({{(128-WB){b_drv[WB-1]}}, b_drv[WB-1:0]})
                                             : $signed({{(128-WB){1'b0}}, b_drv[WB-1:0]});
    wire [127:0] rf = ar * br;
    assign bad = (p !== rf[WA+WB-1:0]);
endmodule

module _zkf_pmul_tb;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg  [63:0] a_drv = 64'd0;
    reg  [63:0] b_drv = 64'd0;
    integer     fails = 0;

    // SS = signed*signed (sincos), UU = unsigned (mul/fma), SU/US mixed. Widths cover the exact sincos shared-
    // multiply sizes (29x20 = WMAN11, 39x24 = WMAN18, 66x41 = WMAN36) plus asymmetric (13x25), matched (18x18),
    // and the minimum widths (3x4) that still allow the 3x3 split. STAGE_PRODUCT 0..3 each.
    localparam integer N = 52;
    wire [N-1:0] bad;
    // Positional connections keep this 44-entry coverage table readable; the helper has a fixed, obvious interface.
    // verilog_lint: waive-start module-parameter
    // verilog_lint: waive-start module-port
    pmul_check #(29, 20, 1, 1, 0) k00 (clk, rst, a_drv, b_drv, bad[0]);
    pmul_check #(29, 20, 1, 1, 1) k01 (clk, rst, a_drv, b_drv, bad[1]);
    pmul_check #(29, 20, 1, 1, 2) k02 (clk, rst, a_drv, b_drv, bad[2]);
    pmul_check #(29, 20, 1, 1, 3) k03 (clk, rst, a_drv, b_drv, bad[3]);
    pmul_check #(29, 20, 0, 0, 0) k04 (clk, rst, a_drv, b_drv, bad[4]);
    pmul_check #(29, 20, 0, 0, 1) k05 (clk, rst, a_drv, b_drv, bad[5]);
    pmul_check #(29, 20, 0, 0, 2) k06 (clk, rst, a_drv, b_drv, bad[6]);
    pmul_check #(29, 20, 0, 0, 3) k07 (clk, rst, a_drv, b_drv, bad[7]);
    pmul_check #(29, 20, 1, 0, 0) k08 (clk, rst, a_drv, b_drv, bad[8]);
    pmul_check #(29, 20, 1, 0, 1) k09 (clk, rst, a_drv, b_drv, bad[9]);
    pmul_check #(29, 20, 1, 0, 2) k10 (clk, rst, a_drv, b_drv, bad[10]);
    pmul_check #(29, 20, 1, 0, 3) k11 (clk, rst, a_drv, b_drv, bad[11]);
    pmul_check #(29, 20, 0, 1, 0) k12 (clk, rst, a_drv, b_drv, bad[12]);
    pmul_check #(29, 20, 0, 1, 1) k13 (clk, rst, a_drv, b_drv, bad[13]);
    pmul_check #(29, 20, 0, 1, 2) k14 (clk, rst, a_drv, b_drv, bad[14]);
    pmul_check #(29, 20, 0, 1, 3) k15 (clk, rst, a_drv, b_drv, bad[15]);
    pmul_check #(39, 24, 1, 1, 0) k16 (clk, rst, a_drv, b_drv, bad[16]);
    pmul_check #(39, 24, 1, 1, 1) k17 (clk, rst, a_drv, b_drv, bad[17]);
    pmul_check #(39, 24, 1, 1, 2) k18 (clk, rst, a_drv, b_drv, bad[18]);
    pmul_check #(39, 24, 1, 1, 3) k19 (clk, rst, a_drv, b_drv, bad[19]);
    pmul_check #(18, 18, 0, 0, 0) k20 (clk, rst, a_drv, b_drv, bad[20]);
    pmul_check #(18, 18, 0, 0, 1) k21 (clk, rst, a_drv, b_drv, bad[21]);
    pmul_check #(18, 18, 0, 0, 2) k22 (clk, rst, a_drv, b_drv, bad[22]);
    pmul_check #(18, 18, 0, 0, 3) k23 (clk, rst, a_drv, b_drv, bad[23]);
    pmul_check #(66, 41, 1, 1, 0) k24 (clk, rst, a_drv, b_drv, bad[24]);
    pmul_check #(66, 41, 1, 1, 1) k25 (clk, rst, a_drv, b_drv, bad[25]);
    pmul_check #(66, 41, 1, 1, 2) k26 (clk, rst, a_drv, b_drv, bad[26]);
    pmul_check #(66, 41, 1, 1, 3) k27 (clk, rst, a_drv, b_drv, bad[27]);
    pmul_check #(66, 41, 1, 0, 0) k28 (clk, rst, a_drv, b_drv, bad[28]);
    pmul_check #(66, 41, 1, 0, 1) k29 (clk, rst, a_drv, b_drv, bad[29]);
    pmul_check #(66, 41, 1, 0, 2) k30 (clk, rst, a_drv, b_drv, bad[30]);
    pmul_check #(66, 41, 1, 0, 3) k31 (clk, rst, a_drv, b_drv, bad[31]);
    pmul_check #(13, 25, 1, 1, 0) k32 (clk, rst, a_drv, b_drv, bad[32]);
    pmul_check #(13, 25, 1, 1, 1) k33 (clk, rst, a_drv, b_drv, bad[33]);
    pmul_check #(13, 25, 1, 1, 2) k34 (clk, rst, a_drv, b_drv, bad[34]);
    pmul_check #(13, 25, 1, 1, 3) k35 (clk, rst, a_drv, b_drv, bad[35]);
    pmul_check #(3,  4,  1, 1, 0) k36 (clk, rst, a_drv, b_drv, bad[36]);
    pmul_check #(3,  4,  1, 1, 1) k37 (clk, rst, a_drv, b_drv, bad[37]);
    pmul_check #(3,  4,  1, 1, 2) k38 (clk, rst, a_drv, b_drv, bad[38]);
    pmul_check #(3,  4,  1, 1, 3) k39 (clk, rst, a_drv, b_drv, bad[39]);
    pmul_check #(3,  4,  0, 0, 3) k40 (clk, rst, a_drv, b_drv, bad[40]);
    pmul_check #(3,  4,  1, 0, 3) k41 (clk, rst, a_drv, b_drv, bad[41]);
    pmul_check #(3,  4,  0, 1, 3) k42 (clk, rst, a_drv, b_drv, bad[42]);
    pmul_check #(18, 18, 1, 1, 0) k43 (clk, rst, a_drv, b_drv, bad[43]);
    // WMULTIPLIER-derived grids (asymmetric where WA != WB), plus the fully-unsigned grid path. P=18 -> signed
    // 66x41 derives 4x3 (M36); unsigned 18x18 derives 1x1 (single tile), 36x36 -> 2x2. P=WMULTIPLIER-1 (signed)
    // vs P=WMULTIPLIER (unsigned). Mix of STAGE_PRODUCT (row-sum at 3, flat at 1/2) and signedness.
    pmul_check #(66, 41, 1, 1, 3, 18) k44 (clk, rst, a_drv, b_drv, bad[44]);  // signed 4x3 (M36 actual)
    pmul_check #(66, 41, 1, 0, 3, 18) k45 (clk, rst, a_drv, b_drv, bad[45]);  // mixed (signed path) 4x3
    pmul_check #(66, 41, 1, 1, 2, 18) k46 (clk, rst, a_drv, b_drv, bad[46]);  // signed 4x3 flat sum
    pmul_check #(30, 50, 1, 1, 3, 18) k47 (clk, rst, a_drv, b_drv, bad[47]);  // signed 2x3 (b wider)
    pmul_check #(18, 18, 0, 0, 1, 18) k48 (clk, rst, a_drv, b_drv, bad[48]);  // unsigned 1x1 (single full tile)
    pmul_check #(36, 36, 0, 0, 3, 18) k49 (clk, rst, a_drv, b_drv, bad[49]);  // unsigned 2x2 (full-width slices)
    pmul_check #(40, 20, 0, 0, 3, 18) k50 (clk, rst, a_drv, b_drv, bad[50]);  // unsigned 3x2
    pmul_check #(50, 50, 0, 0, 2, 12) k51 (clk, rst, a_drv, b_drv, bad[51]);  // unsigned 5x5 (small tile, big grid)
    // verilog_lint: waive-stop module-port
    // verilog_lint: waive-stop module-parameter

    task automatic run_vec(input logic [63:0] av, input logic [63:0] bv);
        begin
            a_drv = av; b_drv = bv;
            repeat (7) @(posedge clk);          // let the deepest pipeline (latency 4) settle on the held inputs
            if (bad !== {N{1'b0}}) begin
                $display("FAIL a=%h b=%h bad=%h", av, bv, bad);
                fails = fails + 1;
            end
        end
    endtask

    integer i, ci, cj;
    reg [63:0] corners [0:8];
    initial begin
        corners[0] = 64'h0000_0000_0000_0000;
        corners[1] = 64'h0000_0000_0000_0001;
        corners[2] = 64'hFFFF_FFFF_FFFF_FFFF;   // -1 / all ones
        corners[3] = 64'h7FFF_FFFF_FFFF_FFFF;
        corners[4] = 64'h8000_0000_0000_0000;
        corners[5] = 64'hAAAA_AAAA_AAAA_AAAA;
        corners[6] = 64'h5555_5555_5555_5555;
        corners[7] = 64'h0000_0000_0001_0000;   // small positive (top bit 0 at every width) -> clean pos x neg
        corners[8] = 64'hFFFF_FFFF_FFFF_FFFB;    // -5

        rst = 1'b1;
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        for (ci = 0; ci <= 8; ci = ci + 1)
            for (cj = 0; cj <= 8; cj = cj + 1)
                run_vec(corners[ci], corners[cj]);

        for (i = 0; i < 4000; i = i + 1)
            run_vec({$urandom, $urandom}, {$urandom, $urandom});

        if (fails != 0) begin
            $display("_zkf_pmul_tb: %0d FAILURE(S)", fails);
            $fatal;
        end
        $display("_zkf_pmul_tb: PASS (all STAGE_PRODUCT x signedness x widths exact)");
        $finish;
    end
endmodule

`default_nettype wire
