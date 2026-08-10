## Arty S7-25 rev. E constraints for the max5715 bench harness.
## Pin assignments come from the Digilent Arty-S7-25 master XDC (see ../doc/arty_s7/Arty-S7-25-Master.xdc),
## which agrees pin for pin with the rev-E schematic (../doc/arty_s7/arty_s7_sch-rev_e.pdf, page 4) and with
## reference-manual table 8.1. The -25 and -50 master XDCs are byte-identical for every pin used here.

set_property -dict { PACKAGE_PIN F14   IOSTANDARD LVCMOS33 } [get_ports { clk12mhz }]
create_clock -add -name sys_clk_pin -period 83.333 -waveform {0 41.667} [get_ports { clk12mhz }]

## Pmod JA. Only the three signals the driver needs are brought out.
##   JA pin 3 (M14) is the DAC's RDY. A single chip does not need it, but it is brought in as an input so the
##   host can count the frames the device actually executes -- an execution telltale independent of the analog
##   measurement. It is only ever read, never driven.
##   JA pins 7 and 9 (M16, M18) are the breakout's LDAC and CLR. They are driven high rather than left to the
##   board's 3 kohm pull-ups, because an unconstrained FPGA pin carries an internal pull of its own that can
##   divide those pull-ups below the 0.7*VDDIO input threshold -- and a CLR that reads low aborts every SPI
##   command, which is indistinguishable from a dead interface. UNUSEDPIN below covers the rest of the header.
set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { dac_cs_n }];    # JA pin 1, JA1_P
set_property -dict { PACKAGE_PIN L18   IOSTANDARD LVCMOS33 } [get_ports { dac_din }];   # JA pin 2, JA1_N
set_property -dict { PACKAGE_PIN N14   IOSTANDARD LVCMOS33 } [get_ports { dac_sclk }];  # JA pin 4, JA2_N
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { dac_rdy }];   # JA pin 3, JA2_P, input
set_property -dict { PACKAGE_PIN M16   IOSTANDARD LVCMOS33 } [get_ports { dac_ldac_n }];# JA pin 7, JA3_P
set_property -dict { PACKAGE_PIN M18   IOSTANDARD LVCMOS33 } [get_ports { dac_clr_n }]; # JA pin 9, JA4_P

## The DAC's setup and hold requirements are relationships between these three outputs, so what matters is
## that their clock-to-out delays track one another. Matching drive and slew keeps the output buffers
## identical; build.tcl constrains the data path only, so the achieved spread appears in the timing report.
set_property SLEW FAST [get_ports { dac_cs_n dac_din dac_sclk }]
set_property DRIVE 12  [get_ports { dac_cs_n dac_din dac_sclk }]

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
## Leave every pin this design does not use genuinely floating, so no internal pull can fight a pull-up on an
## attached board. JA pins 8 and 10 go nowhere on the breakout, but the principle matters for the whole header.
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLNONE [current_design]
