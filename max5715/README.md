# max5715 — driver for the MAX5715 quad 12/10/8-bit SPI DAC

`hdl/max5715.v` streams packed DAC words to one or more MAX5715 devices over their 3-wire SPI interface.
Everything else in this directory exists to verify it: a self-checking testbench, an FPGA bench harness for a
Digilent Arty S7-25, and host tooling that measures the result with an Analog Discovery 3.

The module documentation is provided in its source file.

## Hardware bench

```
vivado -mode batch -source fpga/identify.tcl -nojournal -nolog             # read-only: part and IDCODE
vivado -mode batch -source fpga/build.tcl    -nojournal -nolog -tclargs 2  # 2 -> 50 MHz, 20 -> 5 MHz
vivado -mode batch -source fpga/program.tcl  -nojournal -nolog
~/.venvs/kulibin/bin/python tools/hw_test.py
```

`in_signed` defaults to all-zero in the harness so a commanded value *is* the DAC code, which keeps the measured
transfer function free of interpretation; the host can set the mask to exercise the signed path as well.

### Wiring

Pmod JA of the Arty S7-25 to the MAX5715BOB's 2×6 header. The Arty half comes from the Digilent master XDC and
agrees with the rev-E schematic; the breakout half was derived from its schematic and confirmed against the Pmod
Interface Specification's Type 2A table. The hardware then confirmed it independently: the DAC only has a supply
if IOREF really lands on Pmod pins 6 and 12, which fixes the orientation.

| Pmod JA pin | `ja[]` | FPGA pin | Breakout                    | Driven as                 |
| ---         | ---    | ---      | ---                         | ---                       |
| 1           | ja[0]  | L17      | CSB (`io_cs_n`, active low) | output                    |
| 2           | ja[1]  | L18      | DIN                         | output                    |
| 3           | ja[2]  | M14      | RDY                         | input, execution telltale |
| 4           | ja[3]  | N14      | SCLK                        | output                    |
| 5, 11       | —      | —        | GND                         | —                         |
| 6, 12       | —      | —        | VCC 3.3 V → IOREF           | —                         |
| 7           | ja[4]  | M16      | LDAC                        | output, held high         |
| 9           | ja[6]  | M18      | CLR                         | output, held high         |

**The breakout is not powered from the Pmod connector.** Its VDD/VDDIO come from the board's 5 V rail, fed here
from the Analog Discovery's V+ programmable supply, which `hw_test.py` enables to 5.00 V before doing anything
else. With VDD at 5 V all three internal references are legal, including 4.096 V.

CLR and LDAC are **driven** high rather than left to the breakout's 3 kΩ pull-ups. An unconstrained FPGA pin
carries an internal pull of its own, and a pull-down of a few tens of kΩ divides 3.3 V through those 3 kΩ
towards the 0.7·VDDIO input threshold; a CLR that reads low aborts every SPI command, which is
indistinguishable from a dead interface. `BITSTREAM.CONFIG.UNUSEDPIN PULLNONE` covers the rest of the header.

Analog Discovery 3: analog 1, 2 → OUTA, OUTD; digital 1, 2 → OUTB, OUTC; digital 5, 6, 7 → CSB, SCLK, DIN;
V+ → the 5 V rail; ground commoned with the breakout. The scope inputs are differential, so the negative leads
must be grounded or the readings float. `hw_test.py` *discovers* which digital input follows OUTB and which
follows OUTC rather than trusting this note, so the test stays valid if the probes move.

### Host protocol

| Frame                                             | Reply   | Effect                                                           |
| ---                                               | ---     | ---                                                              |
| `A5` + four big-endian 16-bit codes + xor         | `5A`    | set all four codes and update                                    |
| `B4 ref xor`                                      | `5A`    | re-run configuration with a new reference (pulses `cfg_apply`)   |
| `C3 mask xor`                                     | `5A`    | set the per-channel signed mask                                  |
| `52`                                              | 3 bytes | frames the device executed (counted from RDY), then a flags byte |
| `3F`                                              | `A7`    | ping                                                             |
| bad checksum, or an update while one is in flight | `EE`    | rejected                                                         |

The xor byte is over every preceding byte, so a whole frame exclusive-ors to zero. The `5A` for a code update is
sent only once the driver has *accepted* the sample, so an acknowledgement means the transfer is really on the
wire.

### Linux bring-up notes

Two things had to be fixed before Vivado could see the board, and both recur after a replug:

The Digilent udev rule matches on the `manufacturer` attribute, which FTDI devices populate asynchronously,
so it loses the race at plug time and the USB node is left `0664` instead of `0666`. Without that, the
`digilent-ftdi` plugin reports `cables 0` and no JTAG target is found. Re-run the rules:
`sudo udevadm trigger --action=add --subsystem-match=usb --sysname-match='3-7.1'` (current bus path).

`ftdi_sio` claims *both* FT2232 interfaces, including channel A, which is JTAG. Release just that one:
`echo -n '3-7.1:1.0' | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind`. Interface 1 must stay bound — it is
the UART the host protocol uses.

## Verification status

Verified at the maximum rate: SCLK 50 MHz. The minimum module clk is 100 MHz in this configuration (verified).

| Measurement                       | Result                                                                          | Ideal                    |
| ---                               | ---                                                                             | ---                      |
| OUTA transfer slope               | 611.74 µV/LSB                                                                   | 610.35                   |
| OUTD transfer slope               | 611.57 µV/LSB                                                                   | 610.35                   |
| Offset (intercept)                | −0.9 mV / −0.3 mV                                                               | 0                        |
| Linearity                         | R² = 0.9999997                                                                  | —                        |
| Monotonicity                      | no non-increasing step over 33 codes                                            | —                        |
| Full-scale span                   | 2.5037 V                                                                        | 2.4994                   |
| Simultaneous update               | OUTA and OUTD midpoints 0.5 µs apart                                            | —                        |
| Reference 2.048 / 2.500 / 4.096 V | 2.0506 / 2.5043 / 4.0975 V span                                                 | 2.0475 / 2.4994 / 4.0950 |
| Per-channel signed                | signed channel: 0 → mid scale, most negative → zero scale, neighbour unaffected | —                        |
| Channel mapping                   | word 0 moves only OUTA, word 3 only OUTD                                        | —                        |
| OUTB / OUTC                       | single clean threshold crossing, 16 codes (9.8 mV) apart                        | —                        |

The 0.23 % gain error and few-mV offset are dominated by the instrument, whose specification is ±10 mV ±0.5 % on
this range; they are well inside it. `max5715_transfer_50mhz.csv` and `.png` hold the sweep.

One instrument limitation is worth recording, because it invalidated an earlier version of a check:
`DwfParamDigitalThreshold` reads back as written but does **not** move the threshold of the AD3's static
DigitalIO path — measured crossings sit at ~0.605 V whether it is set to 1400 or 600 mV. The OUTB/OUTC checks
therefore treat the threshold as an unknown constant and assert what is actually establishable: a single clean
crossing, levels that hold either side of it, and agreement between the two channels.
