## Downloads a bitstream to the Arty S7 over Digilent USB-JTAG.
## Usage: vivado -mode batch -source program.tcl -nojournal -nolog [-tclargs <bitfile> [<serial>]]

set here    [file dirname [file normalize [info script]]]
set bitfile [expr {$argc > 0 ? [lindex $argv 0] : [file normalize $here/../../build/fpga/arty_s7_max5715_top.bit]}]
set serial  [expr {$argc > 1 ? [lindex $argv 1] : "210352A895A4"}]

if {![file exists $bitfile]} {
    puts "ERROR: no such bitstream: $bitfile"
    exit 1
}

open_hw_manager
connect_hw_server -allow_non_jtag

## Select by serial rather than taking the first target, so another attached board cannot be programmed.
set tgt {}
foreach t [get_hw_targets] { if {[string match "*$serial*" $t]} { set tgt $t } }
if {$tgt eq ""} {
    puts "ERROR: no hardware target matching $serial; visible targets: [get_hw_targets]"
    exit 1
}

open_hw_target $tgt
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "PROGRAM device=$dev part=[get_property PART $dev]"

set_property PROGRAM.FILE $bitfile $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "PROGRAM done=[get_property REGISTER.IR.BIT5_DONE $dev]"

close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
