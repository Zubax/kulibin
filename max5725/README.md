# max5725 — driver for the MAX5723/MAX5724/MAX5725 octal 8/10/12-bit SPI DAC

`hdl/max5725.v` drives the DAC and contains the usage docs. Everything else here exists to verify it.

The MAX5725 is not a wider MAX5715: opcodes differ and there is no chain mode.

## Hardware bench

```
vivado -mode batch -source fpga/identify.tcl -nojournal -nolog             # read-only: part and IDCODE
vivado -mode batch -source fpga/build.tcl    -nojournal -nolog -tclargs 6  # 6 -> 16.7 MHz, 2 -> 50 MHz
vivado -mode batch -source fpga/program.tcl  -nojournal -nolog
~/.venvs/kulibin/bin/python tools/hw_test.py
```

### Wiring

Pmod JA of the Arty S7-25 to the MAX5725PMB's 2×6 header (J2).

| Pmod JA pin | FPGA pin | J2 pin | Breakout                    |
| ---         | ---      | ---    | ---                         |
| 1           | L17      | 1      | CSB (`io_cs_n`, active low) |
| 2           | L18      | 2      | DIN                         |
| 4           | N14      | 4      | SCLK                        |
| 7           | M16      | 7      | CLR, driven inactive        |
| 8           | M17      | 8      | LDAC, driven inactive       |

The harness drives CLR and LDAC so the board need not: the breakout holds CLR up only through R3, a 1 MΩ
pull-up to VDDIO, and has no pull-up on LDAC at all. J2 pin 3 is DOUT, 9 is IRQ, 5 and 11 GND, 6 and 12
VDD; output header J3 carries OUT0..OUT7 on odd pins 1..15 and ground on the even ones.

Supplies: VDD from the Analog Discovery's V+ at 5 V, and — since JU2 is open — VDDIO must be fed separately,
3.3 V on its test point. An unfed VDDIO does not present as an open circuit: the SPI pins back-power it
through their ESD diodes enough to clock frames in but not to run the core, which looks exactly like a device
ignoring correct frames.

Jumpers: JU1 straps M/Z to VDDIO, JU2 VDDIO to VDD (open), JU3 the on-board MAX6173 into REF (open; the
internal reference is used). JU1 closed makes the power-on and SW_RESET default mid scale, but is outside
spec: M/Z is referenced to VDD, so at VDD = 5 V its VIH is 3.5 V and a 3.3 V strap sits under it. It resolves
high on this unit and every measurement confirms mid scale, but another part or temperature could resolve low.
Open JU1 (R29 pulls M/Z to GND) or run VDD at 3.3 V to stay in spec — the driver works either way, and
`hw_test.py` reports the observed default rather than asserting one.

Analog Discovery 3: analog 1, 2 → OUT0, OUT7; digital → OUT1..OUT6 and the SPI bus; V+ → VDD. Its scope inputs
are differential, so the negative leads must be grounded. Run a real ground wire between the Arty and the
breakout rather than relying on whatever return the instruments provide — see below. `hw_test.py` *discovers*
which digital input follows which output and which three carry the bus, so the test survives moving probes.

The DAC reaches the Arty over loose flying leads with no ground beside the signals.
`SLEW SLOW` rather than `FAST` on the three outputs raised the usable rate: a 1 ns edge into an unterminated
lead rings enough to put false transitions on the quiet CSB line.

The host protocol is defined in the header of `fpga/arty_s7_max5725_top.v`, which implements it.
`tools/max5725_link.py` is the host side.

## Verification status

| Measurement                       | Result                                                                          | Ideal                    |
| ---                               | ---                                                                             | ---                      |
| OUT0 transfer slope               | 612.29 µV/LSB                                                                   | 610.35                   |
| OUT7 transfer slope               | 611.93 µV/LSB                                                                   | 610.35                   |
| Offset (intercept)                | −1.0 mV / −0.1 mV                                                               | 0                        |
| Linearity                         | R² = 0.9999997                                                                  | —                        |
| Monotonicity                      | no non-increasing step over 33 codes                                            | —                        |
| Full-scale span                   | 2.5041 / 2.5034 V                                                               | 2.4994                   |
| Simultaneous update               | OUT0 and OUT7 midpoints under 0.5 µs apart                                      | —                        |
| Reference 2.048 / 2.500 / 4.096 V | 2.0509 / 2.5058 / 4.1011 V span                                                 | 2.0475 / 2.4994 / 4.0950 |
| Per-channel signed                | signed channel: 0 → mid scale, most negative → zero scale, neighbour unaffected | —                        |
| Channel mapping                   | word 0 moves only OUT0, word 7 only OUT7                                        | —                        |
| OUT1..OUT6                        | one clean threshold crossing each, all six at code 992                          | —                        |

The gain error of about 0.2 % and the few-mV offset are dominated by the instrument, whose specification is
±10 mV ±0.5 % on this range. `max5725_transfer.csv` and `.png` hold the sweep.

Rate: This wiring is verified to 16.7 MHz; 25 MHz passes intermittently and 50 MHz not at all, though the
part and the driver both support it. At 50 MHz Vivado closes timing with the clock-to-out spread across the
three DAC pins at 0.077 ns, and a Saleae on the *DAC's own pins* recovers all nine update frames bit-for-bit
from the SCLK edges — DIN and SCLK arrive intact. CSB does not, and tSCLK at 50 MHz is exactly the 20 ns
minimum with no margin for this wiring's ringing. A routed board should reach 50 MHz; flying leads do not.
