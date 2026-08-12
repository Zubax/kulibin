## Non-project-mode synthesis and implementation of the max5725 bench harness for the Arty S7-25.
## Usage: vivado -mode batch -source build.tcl -nojournal -nolog
## Exits nonzero if timing is not met, so the shell can gate on it.

set part xc7s25csga324-1
set top  arty_s7_max5725_top
## Optional first argument overrides the clk-to-io_sclk divider: 2 gives 50 MHz, 4 gives 25 MHz, and so on.
set sclk_div [expr {$argc > 0 ? [lindex $argv 0] : 2}]
set here [file dirname [file normalize [info script]]]
set out  [file normalize $here/../../build/fpga]
file mkdir $out
## Run from the output directory: some report commands drop files (clockInfo.txt) in the working directory
## regardless of their -file argument, and those belong in build/ rather than the repository root.
cd $out

read_verilog [list \
    $here/../hdl/max5725.v \
    $here/uart_rx.v \
    $here/uart_tx.v \
    $here/arty_s7_max5725_top.v \
]

synth_design -top $top -part $part -generic SCLK_DIV=$sclk_div
puts "BUILD SCLK_DIV=$sclk_div (io_sclk = [expr {100.0/$sclk_div}] MHz)"
write_checkpoint -force $out/post_synth.dcp

## Read after synthesis so that the [current_design] properties are applied with a design open.
read_xdc $here/arty_s7_max5725.xdc

## The DAC supplies no clock of its own -- SCLK is generated here -- so there is no external setup or hold
## relationship to constrain, and set_output_delay would be modelling a board requirement that does not exist
## (it also charges the MMCM's clock insertion delay against the budget, which is meaningless here). What the
## DAC's tDS, tDH and tCSS0 margins are actually spent on is the *spread* between these three outputs, so
## constrain the data path only. Vivado then balances and reports the flip-flop-to-pin delays, and the reports
## below give the achieved spread.
set gclk [get_clocks -of_objects [get_pins mmcm/CLKOUT0]]
if {[llength $gclk] == 1} {
    puts "BUILD generated clock: $gclk"
    set_max_delay -datapath_only 7.000 -from [get_clocks $gclk] -to [get_ports {dac_cs_n dac_din dac_sclk}]
} else {
    puts "BUILD ERROR: could not identify the MMCM output clock; the DAC outputs would go unconstrained and\
          their clock-to-out spread unreported, so refuse to build rather than report a hollow success"
    exit 1
}

opt_design
place_design
route_design
write_checkpoint -force $out/post_route.dcp

report_timing_summary -file $out/timing_summary.rpt
report_utilization    -file $out/utilization.rpt
report_drc            -file $out/drc.rpt
report_clocks         -file $out/clocks.rpt

## Clock-to-out of the three DAC pins, both corners; their spread is the skew the DAC sees.
report_timing -to [get_ports {dac_cs_n dac_din dac_sclk}] -delay_type max -max_paths 8 -file $out/dac_out_max.rpt
report_timing -to [get_ports {dac_cs_n dac_din dac_sclk}] -delay_type min -max_paths 8 -file $out/dac_out_min.rpt

## The spread of these three delays is the only externally meaningful timing number in this design: it is the
## skew the DAC sees between SCLK and the data it is supposed to sample against SCLK.
foreach corner {max min} {
    set summary {}
    foreach p {dac_cs_n dac_din dac_sclk} {
        if {[catch {
            set path [get_timing_paths -to [get_ports $p] -delay_type $corner -max_paths 1]
            lappend summary [format "%s=%.3f" $p [get_property DATAPATH_DELAY $path]]
        }]} {
            puts "BUILD ERROR: no timing path reported to $p ($corner corner)"
            exit 1
        }
    }
    puts "BUILD dac output delay ($corner corner): $summary"
}

write_bitstream -force $out/$top.bit

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "BUILD wns=$wns whs=$whs"
if {($wns < 0) || ($whs < 0)} {
    puts "BUILD ERROR: timing not met"
    exit 1
}
puts "BUILD OK: $out/$top.bit"
exit 0
