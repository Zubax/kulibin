/// Frequency divider by a constant. The constant must be a positive integer.
///
/// The first input posedge always produces the first output posedge;
/// that is, the input and output are synchronized at the first cycle.
///
/// The enable input resets the phase to the initial state and sets the output low. This ensures
/// that once the clock is re-enabled, the first input posedge does not come earlier than half-period.
///
/// Output posedges are always aligned with input posedges.
///
/// If N is even or ODD_PERFECT=0 (default), output negedges are always aligned with input posedges;
/// for odd divisors this results in the duty cycle >50%.
///
/// If N is odd and ODD_PERFECT=1, output negedges are always aligned with input negedges
/// and the duty cycle is exactly 50%. This mode mixes the clock with the output logic,
/// which may not be synthesizable in some environments.

module freqdivc#(parameter N=1, parameter ODD_PERFECT=0)(
    input wire clk,
    input wire rst,
    input wire enable,
    output wire out
);
    generate
        if (N <= 1) begin : g_passthrough
            // DEGENERATE CASE --- NO DIVISION
            // The enable is sampled while clk is low so that enabling while clk is already high cannot create an
            // immediate output edge. Reset clears the sampled gate asynchronously; reset assertion may truncate a
            // high pulse, while reset release and enable changes take effect through the low-phase sample point.
            reg sampled_gate;
            assign out = clk & sampled_gate;
            always @(negedge clk or posedge rst) begin
                if (rst) sampled_gate <= 1'b0;
                else sampled_gate <= enable;
            end

        end else if ((N & (N-1)) == 0) begin : g_pow2
            // POWER OF 2 DIVISOR CASE
            reg [$clog2(N)-1:0] cnt;
            assign out = cnt[$clog2(N)-1];
            always @(posedge clk) begin
                if (rst) cnt <= 0;
                else cnt <= enable ? (cnt - 1) : 0;
            end

        end else if (N[0] === 0) begin : g_even
            // EVEN DIVISOR CASE except powers of 2
            reg [$clog2(N/2)-1:0] cnt;
            reg state;
            assign out = state;
            always @(posedge clk) begin
                if (rst) begin
                    cnt <= 0;
                    state <= 0;
                end else begin
                    if (enable) begin
                        if (cnt == 0) begin
                            state <= !state;
                            cnt <= N/2 - 1;
                        end else begin
                            cnt <= cnt - 1;
                        end
                    end else begin
                        cnt <= 0;
                        state <= 0;
                    end
                end
            end

        end else begin : g_odd
            // ODD DIVISOR CASE (N>=3)
            reg state;
            reg [$clog2((N+1)/2)-1:0] cnt;
            wire zero = cnt == 0;
            assign out = state & (ODD_PERFECT ? (clk | !zero) : 1);
            always @(posedge clk) begin
                if (rst) begin
                    cnt <= 0;
                    state <= 0;
                end else begin
                    if (enable) begin
                        if (zero) begin
                            state <= !state;
                            cnt <= state ? (N/2-1) : ((N+1)/2-1);
                        end else begin
                            cnt <= cnt - 1;
                        end
                    end else begin
                        cnt <= 0;
                        state <= 0;
                    end
                end
            end
        end
    endgenerate
endmodule
