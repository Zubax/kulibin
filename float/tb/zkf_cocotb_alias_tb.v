`timescale 1ns/1ps
`default_nettype none

// Placeholder top used by the cocotb runner. The actual DUT is selected per suite at build time via
// cocotb_tools.runner.build(hdl_toplevel=...), so this module is only here to satisfy tools that insist on a default
// top in the fileset. It is not elaborated during real runs; the $finish guards against accidental execution if a
// misconfigured target ever picks it up.
module zkf_cocotb_alias_tb;
    initial begin
        $finish;
    end
endmodule

`default_nettype wire
