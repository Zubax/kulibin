// iverilog -Wall -Wno-timescale -y. iir1_tb.v iir1_lpf_tb.v iir1_hpf_tb.v && vvp a.out

`default_nettype none
`timescale 100ns / 100ns

module iir1_tb;
    wire lpf_done;
    wire hpf_done;

    iir1_lpf_tb#(.FINISH(0)) lpf_tb (
        .done(lpf_done)
    );

    iir1_hpf_tb#(.FINISH(0)) hpf_tb (
        .done(hpf_done)
    );

    initial begin
        $dumpfile("iir1_tb.vcd");
        $dumpvars();
        wait (lpf_done && hpf_done);
        $finish;
    end
endmodule
