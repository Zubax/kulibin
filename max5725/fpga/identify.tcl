## Read-only scan of the JTAG chain: reports the part and IDCODE without touching the configuration memory.
## Usage: vivado -mode batch -source identify.tcl -nojournal -nolog [-tclargs <serial>]
set serial [expr {$argc > 0 ? [lindex $argv 0] : "210352A895A4"}]
open_hw_manager
connect_hw_server -allow_non_jtag
set tgt {}
foreach t [get_hw_targets] { if {[string match "*$serial*" $t]} { set tgt $t } }
if {$tgt eq ""} {
    puts "ERROR: no hardware target matching $serial; visible targets: [get_hw_targets]"
    exit 1
}
open_hw_target $tgt
foreach d [get_hw_devices] {
    current_hw_device $d
    refresh_hw_device -update_hw_probes false $d
    puts "IDENTIFY device=$d part=[get_property PART $d] idcode=[get_property IDCODE $d]"
}
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
