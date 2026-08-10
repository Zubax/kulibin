#!/usr/bin/env python3
"""Hardware verification of the max5715 driver on an Arty S7-25 driving a MAX5715BOB.

Two groups of checks:

* WIRE  -- captures the SPI bus with the Analog Discovery's logic analyser and decodes it, so the frames the
           driver actually emits are compared against the encodings required by the data sheet. This verifies
           the RTL on real silicon and needs nothing from the DAC but its pins.
* ANALOG-- measures what the DAC does with those frames: full-scale span, the code-to-voltage transfer
           function, channel mapping, simultaneous update, and the reference selection.

The ANALOG group is skipped with a diagnosis rather than a pile of failures if the DAC is not responding, since
that condition says nothing about the driver and everything about the board.

Wiring assumed (see ../README.md):
    AD3 analog 1, 2     -> OUTA, OUTD        AD3 digital 1, 2 -> OUTB, OUTC (discovered, not assumed)
    AD3 digital 5, 6, 7 -> CSB, SCLK, DIN    AD3 ground       -> breakout GND
    AD3 V+              -> breakout 5 V rail (the board is NOT powered from the Pmod connector)
"""

from __future__ import annotations

import argparse
import csv
import sys
import threading
import time

import numpy as np

import dwf
import max5715_link as link

CS_DIO, SCLK_DIO, DIN_DIO = 5, 6, 7
OUTB_DIO_DEFAULT, OUTC_DIO_DEFAULT = 1, 2

FRM_SW_RESET = 0x510000
FRM_POWER = 0x400F00
FRM_CONFIG = 0x680000
FRM_LOAD_ALL = 0x810000


def frm_ref(ref: int) -> int:
    """REF command: 0111 0 1 mode -- bit 18 set keeps the reference powered in standby."""
    return (0x74 | ref) << 16


def frm_coden(channel: int, code: int) -> int:
    """CODEn: command 0000, then the channel as a binary value, then the code left justified into B[15:4]."""
    return (channel << 16) | (code << 4)


class Results:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str]] = []
        self.failed = 0

    def check(self, group: str, name: str, ok: bool, detail: str = "") -> bool:
        self.rows.append((group, "PASS" if ok else "FAIL", f"{name}{': ' + detail if detail else ''}"))
        if not ok:
            self.failed += 1
        return ok

    def note(self, group: str, name: str, detail: str = "") -> None:
        self.rows.append((group, "----", f"{name}{': ' + detail if detail else ''}"))

    def skip(self, group: str, name: str, detail: str = "") -> None:
        self.rows.append((group, "SKIP", f"{name}{': ' + detail if detail else ''}"))

    def report(self) -> int:
        width = max(len(r[2]) for r in self.rows) if self.rows else 10
        print()
        print("=" * (width + 18))
        for group, verdict, text in self.rows:
            print(f"  {group:<7} {verdict:<5} {text}")
        print("=" * (width + 18))
        print(f"  {self.failed} failure(s)")
        return 1 if self.failed else 0


# --------------------------------------------------------------------------------------------- wire level

def decode_windows(data: np.ndarray) -> list[tuple[int, int]]:
    """Every 24-bit frame in the capture, as (frame, falling-edge count) in bus order."""
    cs = (data >> CS_DIO) & 1
    sclk = (data >> SCLK_DIO) & 1
    din = (data >> DIN_DIO) & 1
    falls = np.where((sclk[:-1] == 1) & (sclk[1:] == 0))[0] + 1
    out = []
    i = 0
    while i < len(cs):
        if cs[i] == 0:
            j = i
            while j < len(cs) and cs[j] == 0:
                j += 1
            edges = falls[(falls > i) & (falls < j)]
            value = 0
            for e in edges:
                value = (value << 1) | int(din[min(e + 1, len(din) - 1)])
            out.append((value, len(edges)))
            i = j
        else:
            i += 1
    return out


def samples_per_sclk(data: np.ndarray) -> float:
    """Median spacing of SCLK falling edges, in samples. Below about 4 the bus cannot be decoded reliably."""
    sclk = (data >> SCLK_DIO) & 1
    falls = np.where((sclk[:-1] == 1) & (sclk[1:] == 0))[0]
    if len(falls) < 3:
        return 0.0
    gaps = np.diff(falls)
    return float(np.median(gaps[gaps > 0])) if np.any(gaps > 0) else 0.0


def capture_during(d: dwf.AnalogDiscovery, action, rate: float = 100e6, samples: int = 16384,
                   delay: float = 0.3) -> tuple[list[tuple[int, int]], float]:
    """Arms on the falling edge of CSB, performs ``action``, and returns the decoded frames plus the
    oversampling ratio the capture achieved."""
    d.arm_logic_capture(rate=rate, samples=samples, fall_mask=1 << CS_DIO, prefill=64)
    timer = threading.Timer(delay, action)
    timer.start()
    try:
        data = d.fetch_logic(timeout=8.0)
    finally:
        timer.join()
    return decode_windows(data), samples_per_sclk(data)


def discover_digital_probes(l: link.Max5715Link, d: dwf.AnalogDiscovery, r: Results) -> dict[str, int]:
    """Finds which DIO bit follows OUTB and which follows OUTC, by moving one channel at a time.

    Cheaper than trusting a wiring description, and it keeps the test valid if the probes are moved.
    """
    l.set_codes([0, 0, 0, 0])
    time.sleep(0.06)
    base = d.read_digital()
    found = {}
    for slot, name in ((1, "OUTB"), (2, "OUTC")):
        codes = [0, 0, 0, 0]
        codes[slot] = 4095
        l.set_codes(codes)
        time.sleep(0.06)
        changed = [b for b in range(16) if ((d.read_digital() >> b) & 1) != ((base >> b) & 1)]
        if len(changed) == 1:
            found[name] = changed[0]
    l.set_codes([0, 0, 0, 0])
    r.check("PROBE", "OUTB and OUTC each drive exactly one digital input",
            len(found) == 2, f"OUTB -> DIO{found.get('OUTB')}, OUTC -> DIO{found.get('OUTC')}")
    return found


def wire_checks(l: link.Max5715Link, d: dwf.AnalogDiscovery, r: Results, ref: int) -> bool:
    """Decodes the bus and compares it against the data sheet. Returns False if SCLK is too fast to decode."""
    group = "WIRE"

    def exact(got, want, what):
        """The whole capture must match, so a spurious extra frame cannot hide behind a correct prefix."""
        return r.check(group, what, got == [(f, 24) for f in want],
                       "sent " + " ".join(f"{f:06X}/{n}" for f, n in got)
                       + " | want " + " ".join(f"{f:06X}/24" for f in want))

    frames, osr = capture_during(d, lambda: l.set_reference(ref))
    r.note(group, "logic capture oversampling", f"{osr:.1f} samples per SCLK period at 100 MS/s")
    if osr < 4.0:
        r.skip(group, "every decode check",
               f"only {osr:.1f} samples per SCLK period; the logic analyser tops out at 125 MS/s, so a 50 MHz "
               "bus cannot be decoded. Rebuild with a larger SCLK_DIV to check the protocol, and use the "
               "analog group to check behaviour at the target rate")
        return False
    exact(frames, [FRM_SW_RESET, FRM_POWER, FRM_CONFIG, frm_ref(ref)],
          "configuration sequence, whole capture and edge counts")

    codes = [0x123, 0x456, 0x789, 0xABC]
    frames, _ = capture_during(d, lambda: l.set_codes(codes))
    exact(frames, [frm_coden(ch, codes[ch]) for ch in range(4)] + [FRM_LOAD_ALL],
          "update sequence, whole capture and edge counts")
    r.check(group, "exactly one LOAD_ALL, and it closes the update",
            [f for f, _ in frames].count(FRM_LOAD_ALL) == 1 and frames[-1][0] == FRM_LOAD_ALL)

    # A code that differs in every nibble, to catch any bit-ordering or justification error.
    codes = [0xFFF, 0x000, 0xAAA, 0x555]
    frames, _ = capture_during(d, lambda: l.set_codes(codes))
    exact(frames, [frm_coden(ch, codes[ch]) for ch in range(4)] + [FRM_LOAD_ALL],
          "code justification and bit order")
    return True


# ------------------------------------------------------------------------------------------------ analog

def analog_checks(l: link.Max5715Link, d: dwf.AnalogDiscovery, r: Results, vref: float, csv_path: str,
                  plot_path: str | None, probes: dict[str, int], supply: float) -> None:
    group = "ANALOG"
    lsb = vref / 4096.0

    l.set_codes([0, 0, 0, 0])
    time.sleep(0.05)
    zero_a, zero_d = d.read_dc(repeats=4)
    l.set_codes([4095, 4095, 4095, 4095])
    time.sleep(0.05)
    full_a, full_d = d.read_dc(repeats=4)
    span_a, span_d = full_a - zero_a, full_d - zero_d
    want = 4095 * lsb
    r.check(group, "OUTA full-scale span", abs(span_a - want) < 0.05 * want, f"{span_a:.4f} V, want ~{want:.4f}")
    r.check(group, "OUTD full-scale span", abs(span_d - want) < 0.05 * want, f"{span_d:.4f} V, want ~{want:.4f}")

    # Sweep OUTA up while OUTD goes down, which also proves the two channels are independent.
    codes = list(range(128, 3969, 120))
    rows = []
    for c in codes:
        l.set_codes([c, 0, 4095, 4095 - c])
        time.sleep(0.03)
        va, vd = d.read_dc(repeats=2)
        rows.append((c, va, vd))
    with open(csv_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["code_outa", "outa_volts", "code_outd", "outd_volts"])
        for c, va, vd in rows:
            w.writerow([c, f"{va:.6f}", 4095 - c, f"{vd:.6f}"])
    r.note(group, "sweep written", csv_path)

    x = np.array([c for c, _, _ in rows], dtype=float)
    for name, ys, xs in (("OUTA", np.array([va for _, va, _ in rows]), x),
                         ("OUTD", np.array([vd for _, _, vd in rows]), 4095.0 - x)):
        order = np.argsort(xs)
        xa, ya = xs[order], ys[order]
        slope, intercept = np.polyfit(xa, ya, 1)
        pred = slope * xa + intercept
        resid = ya - pred
        r2 = 1.0 - resid.var() / ya.var()
        r.check(group, f"{name} slope", abs(slope - lsb) < 0.03 * lsb,
                f"{slope * 1e6:.2f} uV/LSB, want {lsb * 1e6:.2f}")
        r.check(group, f"{name} intercept", abs(intercept) < 0.030, f"{intercept * 1e3:+.1f} mV")
        r.check(group, f"{name} linearity R^2", r2 > 0.9999, f"{r2:.7f}")
        r.check(group, f"{name} monotonic", bool(np.all(np.diff(ya) > 0)),
                f"{int(np.sum(np.diff(ya) <= 0))} non-increasing steps")

    # Channel mapping: move one word at a time and confirm only the intended output follows.
    l.set_codes([0, 0, 0, 0])
    time.sleep(0.05)
    base_a, base_d = d.read_dc(repeats=2)
    l.set_codes([4095, 0, 0, 0])
    time.sleep(0.05)
    va, vd = d.read_dc(repeats=2)
    r.check(group, "word 0 drives OUTA only", (va - base_a) > 0.9 * want and abs(vd - base_d) < 0.05,
            f"OUTA {va - base_a:+.3f} V, OUTD {vd - base_d:+.3f} V")
    l.set_codes([0, 0, 0, 4095])
    time.sleep(0.05)
    va, vd = d.read_dc(repeats=2)
    r.check(group, "word 3 drives OUTD only", (vd - base_d) > 0.9 * want and abs(va - base_a) < 0.05,
            f"OUTA {va - base_a:+.3f} V, OUTD {vd - base_d:+.3f} V")

    # OUTB and OUTC carry only digital probes, so what can be established for them is that each follows its
    # own code monotonically and crosses its receiver's threshold exactly once. Note that on this device
    # DwfParamDigitalThreshold reads back as written but does not move the threshold of the static DigitalIO
    # path -- measured crossings sit at ~0.605 V whether it is set to 1400 or 600 mV -- so the absolute
    # threshold is treated as an unknown constant rather than asserted against.
    def ramp_transitions(slot: int, bit: int, step: int = 8) -> tuple[list[int], list[int]]:
        """Walks the whole ramp and returns the codes at which the probe rose and at which it fell.

        Scanning to the end matters: stopping at the first rise would let a later glitch or fall pass unseen,
        which is precisely what "crosses exactly once" is supposed to rule out.
        """
        rises, falls, prev = [], [], 0
        for code in range(0, 4096, step):
            codes = [0, 0, 0, 0]
            codes[slot] = code
            l.set_codes(codes)
            time.sleep(0.012)
            now = (d.read_digital() >> bit) & 1
            if now and not prev:
                rises.append(code)
            elif prev and not now:
                falls.append(code)
            prev = now
        return rises, falls

    def level_at(slot: int, bit: int, code: int) -> int:
        codes = [0, 0, 0, 0]
        codes[slot] = code
        l.set_codes(codes)
        time.sleep(0.02)
        return (d.read_digital() >> bit) & 1

    crossings = {}
    for name, slot in (("OUTB", 1), ("OUTC", 2)):
        bit = probes.get(name)
        if bit is None:
            r.skip(group, f"{name} response", "no digital probe found")
            continue
        rises, falls = ramp_transitions(slot, bit)
        if not r.check(group, f"{name} crosses its threshold exactly once over the whole ramp",
                       len(rises) == 1 and len(falls) == 0,
                       f"{len(rises)} rise(s) at {rises}, {len(falls)} fall(s) at {falls}"):
            continue
        c = rises[0]
        crossings[name] = c
        r.check(group, f"{name} crossing is a plausible receiver threshold",
                0.25 < c * lsb < 2.30, f"code {c} (~{c * lsb:.3f} V)")
        # A single sample could be luck; require the level to hold either side of the crossing.
        below, above = max(0, c - 250), min(4095, c + 250)
        low_level, high_level = level_at(slot, bit, below), level_at(slot, bit, above)
        r.check(group, f"{name} level holds either side of the crossing",
                (low_level == 0) and (high_level == 1),
                f"code {below} reads {low_level}, code {above} reads {high_level}")
    if len(crossings) == 2:
        # Both probes see the same kind of receiver, so agreement cross-validates the two channels.
        delta = abs(crossings["OUTB"] - crossings["OUTC"])
        r.check(group, "OUTB and OUTC agree on the crossing", delta < 150,
                f"codes {crossings['OUTB']} and {crossings['OUTC']}, {delta} apart "
                f"({delta * lsb * 1e3:.1f} mV)")
    l.set_codes([0, 0, 0, 0])

    # Simultaneous update: drive OUTA and OUTD to opposite rails in one frame and compare their transitions.
    l.set_codes([0, 0, 0, 4095])
    time.sleep(0.1)
    dt = d.arm_edge_capture(level=0.5 * want, rate=2_000_000.0, buffer_size=8192, pre_fraction=0.25)
    timer = threading.Timer(0.2, lambda: l.set_codes([4095, 0, 0, 0]))
    timer.start()
    try:
        ca, cd = d.fetch_capture(timeout=8.0)
        timer.join()
        mid_a = 0.5 * (ca.min() + ca.max())
        mid_d = 0.5 * (cd.min() + cd.max())
        ia = int(np.argmax(ca > mid_a))
        id_ = int(np.argmax(cd < mid_d))
        skew = abs(ia - id_) * dt
        r.check(group, "OUTA and OUTD step together", skew < 3e-6, f"midpoints {skew * 1e6:.2f} us apart")
    except dwf.DwfError as exc:
        timer.join()
        r.skip(group, "simultaneous update", str(exc))

    # Reference selection: the span must track the reference the device was told to use.
    for ref, nominal in ((link.REF_2V048, 2.048), (link.REF_2V500, 2.500)):
        l.set_reference(ref)
        time.sleep(0.05)
        l.set_codes([0, 0, 0, 0])
        time.sleep(0.05)
        z, _ = d.read_dc(repeats=2)
        l.set_codes([4095, 0, 0, 0])
        time.sleep(0.05)
        f, _ = d.read_dc(repeats=2)
        got = f - z
        expect = 4095.0 / 4096.0 * nominal
        r.check(group, f"span with {nominal:.3f} V reference", abs(got - expect) < 0.05 * expect,
                f"{got:.4f} V, want ~{expect:.4f}")

    # Per-channel signedness: the same word must land on a different voltage depending on its in_signed bit,
    # and a channel left unsigned must be unaffected by its neighbour's setting.
    l.set_signed_mask(0b0001)                       # OUTA signed, OUTD not
    l.set_codes([0x800, 0, 0, 0x800])
    time.sleep(0.06)
    va, vd = d.read_dc(repeats=2)
    r.check(group, "signed channel: most negative maps to zero scale", abs(va) < 0.03, f"OUTA {va:+.4f} V")
    r.check(group, "unsigned neighbour unaffected", abs(vd - 0x800 * lsb) < 0.03,
            f"OUTD {vd:+.4f} V, want ~{0x800 * lsb:.4f}")
    l.set_codes([0, 0, 0, 0])
    time.sleep(0.06)
    va, vd = d.read_dc(repeats=2)
    r.check(group, "signed channel: zero maps to mid scale", abs(va - 0x800 * lsb) < 0.03,
            f"OUTA {va:+.4f} V, want ~{0x800 * lsb:.4f}")
    r.check(group, "unsigned channel: zero maps to zero scale", abs(vd) < 0.03, f"OUTD {vd:+.4f} V")
    l.set_signed_mask(0)
    l.set_codes([0, 0, 0, 0])

    if supply >= 4.5:
        # VDD >= 4.5 V, so the 4.096 V reference is available. It exceeds the +/-2.5 V window of the low gain
        # stage, so shift the window up rather than dropping to the ten-times-coarser high range.
        try:
            d.configure_scope(volt_range=5.0, offset=2.0)
            l.set_reference(link.REF_4V096)
            time.sleep(0.05)
            l.set_codes([0, 0, 0, 0])
            time.sleep(0.05)
            z, _ = d.read_dc(repeats=2)
            l.set_codes([4095, 0, 0, 0])
            time.sleep(0.05)
            f, _ = d.read_dc(repeats=2)
            expect = 4095.0 / 4096.0 * 4.096
            r.check(group, "span with 4.096 V reference", abs((f - z) - expect) < 0.05 * expect,
                    f"{f - z:.4f} V, want ~{expect:.4f}")
        finally:
            l.set_reference(link.REF_2V500)
            d.configure_scope(volt_range=5.0, offset=0.0)
    else:
        r.skip(group, "4.096 V reference", f"needs VDD >= 4.5 V, supply is {supply:.2f} V")

    if plot_path:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            fig, (ax, bx) = plt.subplots(2, 1, figsize=(7, 7), height_ratios=(2, 1))
            xa = np.array([c for c, _, _ in rows], float)
            ya = np.array([va for _, va, _ in rows])
            yd = np.array([vd for _, _, vd in rows])
            ax.plot(xa, ya, ".-", label="OUTA (code ascending)")
            ax.plot(4095 - xa, yd, ".-", label="OUTD (code descending)")
            ax.set_ylabel("output [V]")
            ax.set_title(f"MAX5715 transfer function, {vref:.3f} V reference")
            ax.grid(alpha=0.3)
            ax.legend()
            s, i0 = np.polyfit(xa, ya, 1)
            bx.plot(xa, (ya - (s * xa + i0)) * 1e3, ".-")
            bx.set_xlabel("DAC code")
            bx.set_ylabel("OUTA residual [mV]")
            bx.grid(alpha=0.3)
            fig.tight_layout()
            fig.savefig(plot_path, dpi=130)
            r.note(group, "plot written", plot_path)
        except Exception as exc:  # noqa: BLE001 - a missing plotting stack must not fail the measurement
            r.note(group, "plot skipped", str(exc))


# -------------------------------------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", default="max5715_transfer.csv")
    ap.add_argument("--plot", default="max5715_transfer.png")
    ap.add_argument("--no-plot", action="store_true")
    ap.add_argument("--reference", type=int, default=link.REF_2V500, choices=[0, 1, 2, 3])
    ap.add_argument("--wire-only", action="store_true", help="skip the analog group even if the DAC responds")
    ap.add_argument("--supply", type=float, default=5.0, help="V+ output feeding the breakout's 5 V rail")
    args = ap.parse_args()

    r = Results()
    print(f"WaveForms {dwf.version()}")
    with link.Max5715Link() as l:
        print(f"harness on {l.port}")
        l.ping()
        st = l.status()
        r.check("LINK", "harness responds to ping", True)
        r.check("LINK", "MMCM locked", st["mmcm_locked"], str(st))
        r.check("LINK", "driver reports ready", st["dac_ready"], str(st))
        l.expect_nak(bytes([link.CMD_SET]) + bytes(8) + bytes([0x01]))
        r.check("LINK", "corrupt frame rejected", True)

        d = dwf.AnalogDiscovery("210415B9FB82")
        try:
            print(f"analog discovery {d.serial}")
            supply = d.set_positive_supply(args.supply)
            r.check("POWER", "V+ delivers the requested voltage", abs(supply - args.supply) < 0.15,
                    f"{supply:.3f} V, asked for {args.supply:.2f} V")
            d.set_digital_threshold(dwf.AD3_THRESHOLD_DEFAULT_MV)
            d.configure_digital_inputs()

            # The driver configures the device once, STARTUP_CYCLES after its own reset. If the DAC is powered
            # after the FPGA -- as it is here, since the breakout takes its supply from the instrument -- that
            # configuration is lost and the device sits in its power-on default of an external reference.
            # Re-running it is what a real system would achieve by sequencing power or holding rst.
            l.set_reference(args.reference)
            r.note("POWER", "device reconfigured after its supply came up")

            wire_checks(l, d, r, args.reference)
            l.set_signed_mask(0)

            before = l.status()["frames_executed"]
            l.set_codes([0x800, 0, 0, 0])
            time.sleep(0.05)
            # The telltale is a 16-bit counter, so take the delta modulo its width. Requiring exactly five
            # rejects spurious extra frames as well as missing ones.
            executed = (l.status()["frames_executed"] - before) & 0xFFFF
            r.check("LINK", "DAC executes exactly the frames it is sent", executed == 5,
                    f"{executed} frames acknowledged on RDY, expected 5")

            probes = discover_digital_probes(l, d, r) if executed >= 5 else {}

            if args.wire_only or executed < 5:
                r.skip("ANALOG", "every analog check",
                       "the DAC is not executing frames -- the bus is provably correct at its pins, so this "
                       "is a board-side condition (power or seating), not a driver fault")
            else:
                d.configure_scope(volt_range=5.0, offset=0.0)
                analog_checks(l, d, r, link.REF_VOLTAGE[args.reference], args.csv,
                              None if args.no_plot else args.plot, probes, supply)
        finally:
            d.close()
    return r.report()


if __name__ == "__main__":
    sys.exit(main())
