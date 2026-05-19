/// Sticky-folded right-shift barrel: y = x >> shamt, with y[0] OR-collecting every bit dropped by the shift plus
/// the bit that ends up at position 0. Output y[W-1:1] is the plain shifted value.
/// Used by the adder, to int converter, etc.
///
/// Saturation: when shamt >= W, the cascade naturally produces zero magnitude with sticky = |x.
/// Callers may either rely on that and clamp shamt to W (zkf_to_int does this), or pass a WSHIFT wider than $clog2(W)
/// bits and let the module's own saturation check kick in for over-range values (zkf_add does this).
///
/// Implementation: radix-4 cascade. Each stage selects one of four shifts (0, 4^i, 2*4^i, 3*4^i) with a 4:1 mux;
/// slices commonly pack a 4:1 mux, so the cascade depth is half of the equivalent radix-2 version.

`default_nettype none

module _zkf_rshift_sticky #(parameter W = 16, parameter WSHIFT = $clog2(W) + 1) (
    input  wire      [W-1:0] x,
    input  wire [WSHIFT-1:0] shamt,
    output wire      [W-1:0] y
);
    localparam WLOCAL = $clog2(W);
    localparam NSTAGE = (WLOCAL + 1) / 2;        // radix-4 stages
    localparam WPAIR  = NSTAGE * 2;              // shamt bits the cascade would consume

    // Cascade state: data[i] and sticky[i] after i radix-4 stages.
    wire [W-1:0] data   [0:NSTAGE];
    wire         sticky [0:NSTAGE];
    assign data[0]   = x;
    assign sticky[0] = 1'b0;

    genvar i;
    generate
        for (i = 0; i < NSTAGE; i = i + 1) begin : g_stage
            localparam integer S1 = 1 << (2 * i);     // sel=1
            localparam integer S2 = 1 << (2 * i + 1); // sel=2
            localparam integer S3 = S1 + S2;          // sel=3

            // Each stage's 2-bit selector comes from shamt[2*i +: 2] when both bits are in range, from {0, shamt[2*i]}
            // when only the low bit is in range, or constant 0 when the stage sits above shamt's MSB. Slicing per-stage
            // avoids an intermediate padded `shamt_ext` wire, which empirically confuses Yosys's flatten+ABC pipeline
            // on wide configurations.
            wire [1:0] sel;
            if (2*i + 1 < WSHIFT) begin : g_sel_full
                assign sel = shamt[2*i +: 2];
            end else if (2*i < WSHIFT) begin : g_sel_partial
                assign sel = {1'b0, shamt[2*i]};
            end else begin : g_sel_zero
                assign sel = 2'b00;
            end

            wire [W-1:0] d0 = data[i];
            wire [W-1:0] d1;
            wire [W-1:0] d2;
            wire [W-1:0] d3;
            wire         l1;
            wire         l2;
            wire         l3;

            if (S1 < W) begin : g_s1
                assign d1 = {{S1{1'b0}}, data[i][W-1:S1]};
                assign l1 = |data[i][S1-1:0];
            end else begin : g_s1_sat
                assign d1 = {W{1'b0}};
                assign l1 = |data[i];
            end
            if (S2 < W) begin : g_s2
                assign d2 = {{S2{1'b0}}, data[i][W-1:S2]};
                assign l2 = |data[i][S2-1:0];
            end else begin : g_s2_sat
                assign d2 = {W{1'b0}};
                assign l2 = |data[i];
            end
            if (S3 < W) begin : g_s3
                assign d3 = {{S3{1'b0}}, data[i][W-1:S3]};
                assign l3 = |data[i][S3-1:0];
            end else begin : g_s3_sat
                assign d3 = {W{1'b0}};
                assign l3 = |data[i];
            end

            // 4:1 mux. Ternary chain in this exact form maps to a mux-friendly pattern.
            assign data[i+1] = (sel == 2'd0) ? d0
                             : (sel == 2'd1) ? d1
                             : (sel == 2'd2) ? d2
                             :                 d3;
            assign sticky[i+1] = sticky[i]
                               | ((sel == 2'd1) & l1)
                               | ((sel == 2'd2) & l2)
                               | ((sel == 2'd3) & l3);
        end
    endgenerate

    // Top-of-range saturation: if shamt has bits set above what the cascade consumes, collapse to {0, |x}.
    // With WSHIFT <= WPAIR this resolves to a constant 1'b0 at elaboration.
    wire shamt_ge_w;
    generate
        if (WSHIFT > WPAIR) begin : g_sat_check
            assign shamt_ge_w = |shamt[WSHIFT-1:WPAIR];
        end else begin : g_no_sat_check
            assign shamt_ge_w = 1'b0;
        end
    endgenerate

    wire [W-1:0] final_data;
    wire         final_sticky;
    assign final_data   = shamt_ge_w ? {W{1'b0}} : data[NSTAGE];
    assign final_sticky = shamt_ge_w ? |x         : sticky[NSTAGE];

    assign y[W-1:1] = final_data[W-1:1];
    assign y[0]     = final_data[0] | final_sticky;
endmodule

`default_nettype wire
