/// iverilog -Wall -Wno-timescale -y. sine_lookup_1024_tb.v && vvp a.out > sine.tab
/// Then analyze the dump using Jupyter.

module sine_lookup_1024_tb;
    reg [9:0] x;
    wire signed [9:0] out;
    sine_lookup_1024 sine (.x(x), .out(out));

    integer i;
    initial begin
        $dumpfile("sine_lookup_1024_tb.vcd");
        $dumpvars();

        for (i = 0; i < 1024; i++) begin
            # 1 x = i[9:0];
            # 1
            $display(x, " ", out);
        end
        # 1 $finish();
    end
endmodule
