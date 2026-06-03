/// Folded (iterative) CORDIC engine shared by the ZKF trigonometric operators. One (x, y, z) datapath is reused over
/// several cycles, a configurable number of iterations unrolled per cycle, instead of an N-stage pipeline -- so the
/// area is a single datapath at the cost of an initiation interval equal to the latency.
///
/// UNROLL100 is the latency knob (iterations per cycle x100); pick the largest that closes timings:
///     50 = one iteration per two cycles (split shift/add to halve the per-iteration combinational path, at 2N cycles);
///     100 = one iteration per cycle;
///     200/300/400 = 2/3/4 iterations per cycle (fewer cycles, longer path).
///
/// MODE selects the trajectory; the x/y/z update is otherwise identical:
///
///   MODE = 0 (ROTATION):  sigma_i = (z_i >= 0) ? +1 : -1   -- drives the angle z to 0; (x, y) rotates by z0.
///                         Used by zkf_sincos with (x0, y0) = (1/gain, 0) so (xn, yn) ~ (cos z0, sin z0) and
///                         zn is the small residual the wrapper finishes with one linear rotation.
///
///   MODE = 1 (VECTORING): sigma_i = (y_i >= 0) ? -1 : +1   -- drives y to 0; zn = z0 + atan2(y0, x0), xn ~ |(x0,y0)|.
///                         Used by zkf_atan2.
///
/// Each iteration: x' = x -/+ (y >>> i); y' = y +/- (x >>> i); z' = z -/+ L[i]. The shift `>>> i` truncates toward
/// -inf (matches the Python model's `>> i`). In the fold the shift amount i is the running iteration index, so it is a
/// variable (barrel) shift and L[i] is a variable index into the flat LUT bus -- unlike the pipelined CORDIC's
/// per-stage constant shifts. Each update is one controlled add/sub (a + (b ^ {W{sub}}) + sub -> one CCU2 chain).
///
/// Handshake: assert `start` for one cycle with x0/y0/z0 valid; `busy` is high while iterating; `done` pulses for one
/// cycle with xn/yn/zn (and the registered sideband sb_out) valid. `start` is ignored while busy. Reset clears the FSM.

`default_nettype none

module _zkf_cordic #(
    parameter integer N         = 14,  // iterations
    parameter integer UNROLL100 = 100, // iters/cycle x100: 50=half-rate, 100/200/300/400=1/2/3/4 per cycle
    parameter integer WX        = 32,  // signed x/y width
    parameter integer WZ        = 32,  // signed angle width
    parameter integer MODE      = 0,   // 0 = rotation, 1 = vectoring
    parameter integer WSB       = 1    // sideband carried from start to done
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 start,
    input  wire       [WSB-1:0] sb_in,
    input  wire signed [WX-1:0] x0,
    input  wire signed [WX-1:0] y0,
    input  wire signed [WZ-1:0] z0,
    // verilator coverage_off
    input  wire      [N*WZ-1:0] lut,      // L[i] (unsigned) at bits [i*WZ +: WZ]
    // verilator coverage_on
    output wire                 busy,
    output wire                 done,
    output wire       [WSB-1:0] sb_out,
    output wire signed [WX-1:0] xn,
    output wire signed [WX-1:0] yn,
    output wire signed [WZ-1:0] zn
);
    localparam integer U    = (UNROLL100 < 100) ? 1 : (UNROLL100 / 100);
    localparam integer PIPE = (UNROLL100 < 100) ? 1 : 0;
    localparam integer WI   = $clog2(N + U + 1);  // iteration-index width (holds i_r + U and idx = i_r + u, no wrap)

    // verilator coverage_off
    generate
        if ((UNROLL100 != 50) && ((UNROLL100 < 100) || ((UNROLL100 % 100) != 0))) begin : g_invalid_unroll100
            _zkf_invalid_unroll100 u_invalid();
        end
    endgenerate
    // verilator coverage_on

    reg signed [WX-1:0] x_r, y_r;
    reg signed [WZ-1:0] z_r;
    reg        [WI-1:0] i_r;                   // base iteration index for this cycle
    reg                 run_r, done_r;
    reg       [WSB-1:0] sb_r;

    generate
        if (PIPE == 0) begin : g_fast
            // U iterations per cycle. Combinational chain from the registered state, starting at index i_r.
            // Iterations whose index reaches N pass through as-is (last cycle may be a partial group if N % U != 0).
            // verilator coverage_off
            wire signed [WX-1:0] cx [0:U];
            wire signed [WX-1:0] cy [0:U];
            wire signed [WZ-1:0] cz [0:U];
            // verilator coverage_on
            assign cx[0] = x_r;
            assign cy[0] = y_r;
            assign cz[0] = z_r;

            genvar u;
            for (u = 0; u < U; u = u + 1) begin : g_unroll
                wire [WI-1:0]        idx   = i_r + u[WI-1:0];
                wire                 en    = (idx < N[WI-1:0]);
                wire signed [WX-1:0] ysh   = cy[u] >>> idx;
                wire signed [WX-1:0] xsh   = cx[u] >>> idx;
                wire [WZ-1:0]        li    = lut[idx*WZ +: WZ];
                wire                 neg   = (MODE == 0) ? cz[u][WZ-1] : ~cy[u][WX-1];  // true => sigma = -1
                wire                 sub_x = ~neg;      // x subtracts ysh when sigma = +1
                wire                 sub_y =  neg;      // y subtracts xsh when sigma = -1
                wire                 sub_z = ~neg;      // z subtracts li  when sigma = +1
                wire signed [WX-1:0] nx    = cx[u] + (ysh ^ {WX{sub_x}}) + {{(WX-1){1'b0}}, sub_x};
                wire signed [WX-1:0] ny    = cy[u] + (xsh ^ {WX{sub_y}}) + {{(WX-1){1'b0}}, sub_y};
                wire signed [WZ-1:0] nz    = cz[u] + ($signed({1'b0, li}) ^ {WZ{sub_z}}) + {{(WZ-1){1'b0}}, sub_z};
                assign cx[u+1] = en ? nx : cx[u];
                assign cy[u+1] = en ? ny : cy[u];
                assign cz[u+1] = en ? nz : cz[u];
            end

            // i_r is the iteration counter that advances unconditionally, so latency stays constant data-independent.
            wire last = (i_r + U[WI-1:0]) >= N[WI-1:0];   // this cycle finishes the final group

            always @(posedge clk) begin
                if (rst) begin
                    run_r  <= 1'b0;
                    done_r <= 1'b0;
                end else begin
                    done_r <= 1'b0;
                    if (!run_r) begin
                        if (start) begin
                            x_r <= x0; y_r <= y0; z_r <= z0; i_r <= {WI{1'b0}};
                            sb_r <= sb_in;
                            // N == 0 (no iterations) completes immediately; otherwise iterate.
                            run_r  <= (N != 0);
                            done_r <= (N == 0);
                        end
                    end else begin
                        x_r <= cx[U]; y_r <= cy[U]; z_r <= cz[U];
                        i_r <= i_r + U[WI-1:0];
                        if (last) begin
                            run_r  <= 1'b0;
                            done_r <= 1'b1;
                        end
                    end
                end
            end
        end else begin : g_pipe
            // One iteration per 2 cycles for wide datapaths: phase 0 registers the shifted operands and the controls
            // sampled at the current (x, y, z); phase 1 applies the add/sub. This splits the long shift -> wide-add
            // cone across a register so the recurrence closes timing. The cost is 2*N cycles.
            reg                 phase_r;           // 0 = shift/sample, 1 = add/advance
            reg signed [WX-1:0] xsh_r, ysh_r;      // x>>>i, y>>>i sampled in phase 0
            reg        [WZ-1:0] li_r;
            reg                 neg_r;             // sigma sign sampled in phase 0 (true => sigma = -1)
            // verilator coverage_off
            wire [WI-1:0]        idx = i_r;
            wire signed [WX-1:0] xsh = x_r >>> idx;
            wire signed [WX-1:0] ysh = y_r >>> idx;
            wire [WZ-1:0]        li  = lut[idx*WZ +: WZ];
            wire                 neg = (MODE == 0) ? z_r[WZ-1] : ~y_r[WX-1];
            wire                 sub_x = ~neg_r;
            wire                 sub_y =  neg_r;
            wire                 sub_z = ~neg_r;
            wire signed [WX-1:0] nx = x_r + (ysh_r ^ {WX{sub_x}}) + {{(WX-1){1'b0}}, sub_x};
            wire signed [WX-1:0] ny = y_r + (xsh_r ^ {WX{sub_y}}) + {{(WX-1){1'b0}}, sub_y};
            wire signed [WZ-1:0] nz = z_r + ($signed({1'b0, li_r}) ^ {WZ{sub_z}}) + {{(WZ-1){1'b0}}, sub_z};
            wire last = (i_r + 1'b1) >= N[WI-1:0];
            // verilator coverage_on
            always @(posedge clk) begin
                if (rst) begin
                    run_r   <= 1'b0;
                    done_r  <= 1'b0;
                    phase_r <= 1'b0;
                end else begin
                    done_r <= 1'b0;
                    if (!run_r) begin
                        if (start) begin
                            x_r <= x0; y_r <= y0; z_r <= z0; i_r <= {WI{1'b0}};
                            sb_r <= sb_in; phase_r <= 1'b0;
                            run_r  <= (N != 0);
                            done_r <= (N == 0);
                        end
                    end else if (phase_r == 1'b0) begin
                        xsh_r <= xsh; ysh_r <= ysh; li_r <= li; neg_r <= neg;
                        phase_r <= 1'b1;
                    end else begin
                        x_r <= nx; y_r <= ny; z_r <= nz;
                        i_r <= i_r + 1'b1;
                        phase_r <= 1'b0;
                        if (last) begin
                            run_r  <= 1'b0;
                            done_r <= 1'b1;
                        end
                    end
                end
            end
        end
    endgenerate

    assign busy   = run_r;
    assign done   = done_r;
    assign xn     = x_r;
    assign yn     = y_r;
    assign zn     = z_r;
    assign sb_out = sb_r;
endmodule

`default_nettype wire
