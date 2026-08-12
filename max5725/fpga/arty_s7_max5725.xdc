## Arty S7-25 rev. E constraints for the max5725 bench harness.
## Pin assignments come from the Digilent Arty-S7-25 master XDC (see ../../_docs/arty_s7/Arty-S7-25-Master.xdc),
## which agrees pin for pin with the rev-E schematic (../../_docs/arty_s7/arty_s7_sch-rev_e.pdf, page 4) and
## with reference-manual table 8.1.

set_property -dict { PACKAGE_PIN F14   IOSTANDARD LVCMOS33 } [get_ports { clk12mhz }]
create_clock -add -name sys_clk_pin -period 83.333 -waveform {0 41.667} [get_ports { clk12mhz }]

## Pmod JA. DOUT and IRQ are unused; UNUSEDPIN below leaves the rest of the header genuinely floating so no
## internal pull can fight anything on the board.
set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { dac_cs_n }]; # JA pin 1, JA1_P
set_property -dict { PACKAGE_PIN L18   IOSTANDARD LVCMOS33 } [get_ports { dac_din }];  # JA pin 2, JA1_N
set_property -dict { PACKAGE_PIN N14   IOSTANDARD LVCMOS33 } [get_ports { dac_sclk }]; # JA pin 4, JA2_N
## Not part of the driver, which needs three pins: these are driven inactive because the breakout pulls CLR up
## only through 1 Mohm and does not pull LDAC at all.
set_property -dict { PACKAGE_PIN M16   IOSTANDARD LVCMOS33 } [get_ports { dac_clr_n }];  # JA pin 7, JA3_P
set_property -dict { PACKAGE_PIN M17   IOSTANDARD LVCMOS33 } [get_ports { dac_ldac_n }]; # JA pin 8, JA3_N

## The DAC's setup and hold budgets are relationships between these three outputs, so what matters is that
## their clock-to-out delays track; matching drive and slew keeps the buffers identical, and build.tcl
## constrains the data path so the achieved spread appears in the timing report. SLOW rather than FAST because
## this bench reaches the DAC over loose flying leads: a 1 ns edge into those rings enough to put false
## transitions on CSB. A board that routes these signals properly can and should use FAST.
set_property SLEW SLOW [get_ports { dac_cs_n dac_din dac_sclk }]
set_property DRIVE 16  [get_ports { dac_cs_n dac_din dac_sclk }]

## USB-UART bridge. The names are from the bridge's point of view: uart_rxd_out is an FPGA output.
set_property -dict { PACKAGE_PIN R12   IOSTANDARD LVCMOS33 } [get_ports { uart_rxd_out }]
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { uart_txd_in }]

## Button and LEDs
set_property -dict { PACKAGE_PIN G15   IOSTANDARD LVCMOS33 } [get_ports { btn0 }]
set_property -dict { PACKAGE_PIN E18   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN F13   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN E13   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN H15   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Configuration. No bank-34 pin is used, so the master XDC's INTERNAL_VREF line is intentionally omitted.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLNONE [current_design]
