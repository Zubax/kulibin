#!/usr/bin/env python3
"""Hardware verification of the max5725 driver on an Arty S7-25 driving a MAX5725PMB.

Three groups of checks:

* PROBE  -- works out which instrument channel is watching what, by moving one thing at a time, so nothing
            about the probe assignment is assumed and the test survives the leads being moved.
* WIRE   -- captures the SPI bus and decodes it, comparing the frames the driver emits against the encodings
            the data sheet requires. Needs about four samples per SCLK period; see ../README.md for the build.
* ANALOG -- measures what the DAC does with those frames: span, transfer function, channel mapping,
            simultaneous update, reference selection and the signed path.

If the DAC is not responding the ANALOG group is skipped with a diagnosis rather than a pile of failures,
since that says nothing about the driver. Wiring and jumpers are documented in ../README.md.
"""

from __future__ import annotations

import argparse
import csv
import itertools
import sys
import threading
import time

import numpy as np

import dwf
import max5725_link as link

CHANNELS = link.CHANNELS
FULL_SCALE = link.CODE_MAX                      # 4095
SCOPE_CHANNELS = (0, 7)                         # Analog 1 and 2 watch these outputs
DIGITAL_CHANNELS = (1, 2, 3, 4, 5, 6)           # The rest are seen only through the logic receivers

FRM_SW_RESET = 0x359630
FRM_POWER = 0x40FF00
FRM_CONFIG = 0x50FF28
FRM_LOAD_ALL = 0xC10000


def frm_ref(ref: int) -> int:
    """REF command: 0010 0 1 mode -- B18 set keeps the reference powered even in standby."""
    return (0x24 | ref) << 16


def frm_coden(channel: int, code: int) -> int:
    """CODEn: command 1000, B19 clear, then the channel in B[18:16] and the code left justified into B[15:4]."""
    return 0x800000 | (channel << 16) | (code << 4)


def codes_with(**kwargs) -> list[int]:
    """A full set of eight codes, zero except where named, e.g. codes_with(c3=4095)."""
    out = [0] * CHANNELS
    for key, value in kwargs.items():
        out[int(key[1:])] = value
    return out


class Results:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str]] = []
        self.failed = 0

    def passes(self, group: str) -> int:
        return sum(1 for g, verdict, _ in self.rows if g == group and verdict == "PASS")

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
        skipped = sum(1 for _, verdict, _ in self.rows if verdict == "SKIP")
        passed = sum(1 for _, verdict, _ in self.rows if verdict == "PASS")
        print("=" * (width + 18))
        # Skips are shown next to failures because a skip is not a pass: a run in which a whole group was
        # skipped verifies far less than a bare failure count of zero suggests.
        print(f"  {self.failed} failure(s), {skipped} skipped, {passed} passed")
        return 1 if self.failed else 0


# --------------------------------------------------------------------------------------------- wire level

class Bus:
    """Which DIO bit carries which SPI signal."""

    def __init__(self, cs: int, sclk: int, din: int) -> None:
        self.cs, self.sclk, self.din = cs, sclk, din

    def __str__(self) -> str:
        return f"CSB -> DIO{self.cs}, SCLK -> DIO{self.sclk}, DIN -> DIO{self.din}"


def _edges(bits: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Indices of the rising and falling transitions of a 0/1 array."""
    rises = np.where((bits[:-1] == 0) & (bits[1:] == 1))[0] + 1
    falls = np.where((bits[:-1] == 1) & (bits[1:] == 0))[0] + 1
    return rises, falls


def _deglitch(bits: np.ndarray, min_run: int = 6) -> np.ndarray:
    """Removes runs shorter than ``min_run`` samples, absorbing them into the preceding level.

    Nothing genuine on this bus is that short, but flying probe leads are: one spurious sample splits a frame
    into several windows of a few edges each, which reads as a driver emitting nonsense rather than as noise.
    """
    if len(bits) < 2:
        return bits
    edges = np.flatnonzero(np.diff(bits)) + 1
    bounds = np.concatenate(([0], edges, [len(bits)]))
    out = bits.copy()
    for start, end in zip(bounds[:-1], bounds[1:]):
        if (end - start) < min_run and start > 0:
            out[start:end] = out[start - 1]
    return out


def min_run_for(rate: float) -> int:
    """Deglitch threshold in samples: about 50 ns, which no legitimate level on this bus is shorter than."""
    return max(2, int(round(rate * 50e-9)))


def _windows(cs: np.ndarray, min_run: int = 6) -> list[tuple[int, int]]:
    """Half-open [start, end) index ranges over which the chip select is asserted."""
    cs = _deglitch(cs, min_run)
    out, i, n = [], 0, len(cs)
    while i < n:
        if cs[i] == 0:
            j = i
            while j < n and cs[j] == 0:
                j += 1
            # Discard a window clipped by either end of the buffer; it carries no complete frame.
            if i > 0 and j < n:
                out.append((i, j))
            i = j
        else:
            i += 1
    return out


def bus_is_plausible(data: np.ndarray, bus: Bus, min_run: int = 6) -> bool:
    """Structural test of one candidate assignment, independent of what the frames contain.

    Only the chip select idles high, and only the clock is parked low between windows and falls exactly 24
    times inside each -- which no 24-bit data pattern can do. At most one assignment satisfies all of that.
    """
    cs = (data >> bus.cs) & 1
    sclk = (data >> bus.sclk) & 1
    if cs[0] != 1 or cs[-1] != 1:
        return False
    wins = _windows(cs, min_run)
    if not wins:
        return False
    _, falls = _edges(sclk)
    for start, end in wins:
        if int(np.count_nonzero((falls > start) & (falls < end))) != 24:
            return False
    # Outside the windows the clock must be quiet, which is what tells SCLK apart from a busy data line.
    quiet = np.ones(len(sclk), dtype=bool)
    for start, end in wins:
        quiet[start:end] = False
    return bool(np.all(sclk[quiet] == 0))


def decode_windows(data: np.ndarray, bus: Bus, min_run: int = 6) -> list[tuple[int, int]]:
    """Every frame in the capture, as (value, falling-edge count) in bus order."""
    cs = (data >> bus.cs) & 1
    sclk = (data >> bus.sclk) & 1
    din = (data >> bus.din) & 1
    _, falls = _edges(sclk)
    out = []
    for start, end in _windows(cs, min_run):
        edges = falls[(falls > start) & (falls < end)]
        value = 0
        for e in edges:
            # The device latches DIN on the falling edge, so sample just after it.
            value = (value << 1) | int(din[min(e + 1, len(din) - 1)])
        out.append((value, len(edges)))
    return out


def samples_per_sclk(data: np.ndarray, bus: Bus, min_run: int = 6) -> float:
    """Samples per SCLK period, measured inside the windows where the clock actually runs.

    A median gap between falling edges over the whole capture reads far too high once the clock aliases: it
    reported 15 samples per period for a 50 MHz bus sampled at 25 MS/s. A window's span divided by its edges
    does not, since an aliased window is short.
    """
    cs = (data >> bus.cs) & 1
    _, falls = _edges((data >> bus.sclk) & 1)
    ratios = []
    for start, end in _windows(cs, min_run):
        n = int(np.count_nonzero((falls > start) & (falls < end)))
        if n >= 2:
            ratios.append((end - start) / float(n))
    return float(np.median(ratios)) if ratios else 0.0


def capture_during(d: dwf.AnalogDiscovery, action, fall_mask: int, rate: float = 125e6,
                   samples: int = 16384, delay: float = 0.3) -> tuple[np.ndarray, float]:
    """Arms the logic analyser, performs ``action`` from a timer, and returns the capture and its real rate."""
    achieved = d.arm_logic_capture(rate=rate, samples=samples, fall_mask=fall_mask, prefill=64)
    timer = threading.Timer(delay, action)
    timer.start()
    try:
        return d.fetch_logic(timeout=8.0), achieved
    finally:
        timer.join()


def discover_output_probes(l: link.Max5725Link, d: dwf.AnalogDiscovery, r: Results) -> dict[int, int]:
    """Finds which DIO bit follows which of OUT1..OUT6, by driving one channel at a time to full scale."""
    l.set_codes([0] * CHANNELS)
    time.sleep(0.08)
    base = d.read_digital()
    found: dict[int, int] = {}
    for ch in DIGITAL_CHANNELS:
        l.set_codes(codes_with(**{f"c{ch}": FULL_SCALE}))
        time.sleep(0.06)
        changed = [b for b in range(16) if ((d.read_digital() >> b) & 1) != ((base >> b) & 1)]
        if len(changed) == 1:
            found[ch] = changed[0]
    l.set_codes([0] * CHANNELS)
    r.check("PROBE", "each of OUT1..OUT6 drives exactly one digital input",
            len(found) == len(DIGITAL_CHANNELS) and len(set(found.values())) == len(found),
            ", ".join(f"OUT{c} -> DIO{b}" for c, b in sorted(found.items())) or "none identified")
    return found


def discover_bus(l: link.Max5725Link, d: dwf.AnalogDiscovery, r: Results, used: set[int]) -> Bus | None:
    """Works out which DIO bits carry CSB, SCLK and DIN from the shape of the traffic alone.

    The structural test is exact but needs a decodable capture; above about 25 MHz the clock aliases and
    nothing satisfies it. The far weaker activity ranking then only serves to report why the decode skipped.
    """
    spare = [b for b in range(16) if b not in used]
    # Trigger on any falling edge of a line that is not already spoken for; CSB falls first in every frame.
    mask = 0
    for b in spare:
        mask |= 1 << b
    # The structural test needs one clean capture. A glitch on a probe lead spoils it now and then, and the
    # fallback below is much weaker, so retry a couple of times before settling for it.
    for _ in range(3):
        data, rate = capture_during(d, lambda: l.set_codes(codes_with(c0=0xA5A, c7=0x5A5)), fall_mask=mask)
        run = min_run_for(rate)
        active_now = [b for b in spare
                      if int(np.count_nonzero(((data >> b) & 1)[:-1] != ((data >> b) & 1)[1:])) > 0]
        if len(active_now) >= 3 and any(bus_is_plausible(data, Bus(*p), run)
                                        for p in itertools.permutations(active_now, 3)):
            break

    counts = {b: int(np.count_nonzero(((data >> b) & 1)[:-1] != ((data >> b) & 1)[1:])) for b in spare}
    active = [b for b, n in counts.items() if n > 0]
    if len(active) < 3:
        r.check("PROBE", "SPI bus probes visible", False,
                f"only {len(active)} spare digital input(s) moved: {active}")
        return None

    matches = [Bus(*p) for p in itertools.permutations(active, 3) if bus_is_plausible(data, Bus(*p), run)]
    if len(matches) == 1:
        r.check("PROBE", "SPI bus probes identified", True, f"{matches[0]} (structurally)")
        return matches[0]

    # Ranking fallback: the clock carries by far the most edges, and only the chip select idles high.
    ranked = sorted(active, key=lambda b: counts[b], reverse=True)
    sclk = ranked[0]
    idle_high = [b for b in ranked[1:] if ((data >> b) & 1)[0] == 1 and ((data >> b) & 1)[-1] == 1]
    if len(matches) > 1 or not idle_high:
        r.check("PROBE", "SPI bus probes identify uniquely", False,
                f"{len(matches)} structural match(es) among active lines "
                + ", ".join(f"DIO{b}:{counts[b]}" for b in ranked))
        return None
    cs = min(idle_high, key=lambda b: counts[b])
    din = [b for b in ranked if b not in (sclk, cs)][0]
    guess = Bus(cs, sclk, din)
    r.note("PROBE", "SPI bus probes identified by activity only",
           f"{guess}; edge counts " + ", ".join(f"DIO{b}:{counts[b]}" for b in ranked))
    return guess


def wire_checks(l: link.Max5725Link, d: dwf.AnalogDiscovery, r: Results, bus: Bus, ref: int) -> None:
    """Decodes the bus and compares it against the data sheet."""
    group = "WIRE"
    mask = 1 << bus.cs

    def exact(frames, want, what):
        """The whole capture must match, so a spurious extra frame cannot hide behind a correct prefix."""
        return r.check(group, what, frames == [(f, 24) for f in want],
                       "sent " + " ".join(f"{f:06X}/{n}" for f, n in frames)
                       + " | want " + " ".join(f"{f:06X}/24" for f in want))

    data, rate = capture_during(d, lambda: l.set_reference(ref), fall_mask=mask)
    cfg_run = min_run_for(rate)
    osr = samples_per_sclk(data, bus, cfg_run)
    dt_ns = 1e9 / rate
    r.note(group, "logic capture", f"{rate / 1e6:.1f} MS/s, {osr:.1f} samples per SCLK period")
    if osr < 4.0:
        r.skip(group, "every decode check",
               f"only {osr:.1f} samples per SCLK period at {rate / 1e6:.0f} MS/s, so the bus cannot be "
               "decoded. Rebuild with a larger SCLK_DIV to check the protocol, and use the analog group to "
               "check behaviour at the target rate")
        return
    exact(decode_windows(data, bus, cfg_run), [FRM_SW_RESET, FRM_POWER, FRM_CONFIG, frm_ref(ref)],
          "configuration sequence, whole capture and edge counts")

    codes = [0x123, 0x456, 0x789, 0xABC, 0xDEF, 0x02F, 0xF10, 0x8C3]
    data, rate = capture_during(d, lambda: l.set_codes(codes), fall_mask=mask)
    upd_run = min_run_for(rate)
    dt_ns = 1e9 / rate
    frames = decode_windows(data, bus, upd_run)
    exact(frames, [frm_coden(ch, codes[ch]) for ch in range(CHANNELS)] + [FRM_LOAD_ALL],
          "update sequence, whole capture and edge counts")
    r.check(group, "exactly one LOAD_ALL, and it closes the update",
            [f for f, _ in frames].count(FRM_LOAD_ALL) == 1 and bool(frames) and frames[-1][0] == FRM_LOAD_ALL)

    # A code that differs in every nibble, to catch any bit-ordering or justification error.
    codes = [0xFFF, 0x000, 0xAAA, 0x555, 0x001, 0x800, 0x00F, 0xF00]
    data, _ = capture_during(d, lambda: l.set_codes(codes), fall_mask=mask)
    exact(decode_windows(data, bus, upd_run),
          [frm_coden(ch, codes[ch]) for ch in range(CHANNELS)] + [FRM_LOAD_ALL],
          "code justification and bit order")
    timing_checks(data, bus, dt_ns, r, upd_run)


def timing_checks(data: np.ndarray, bus: Bus, dt_ns: float, r: Results, min_run: int = 6) -> None:
    """Bus intervals measured at the DAC's own pins, against the data sheet minima.

    Says nothing about a 50 MHz build, whose bus is too fast for this analyser; there the margins come from
    the Vivado timing report and from the DAC working.
    """
    group = "WIRE"
    cs = (data >> bus.cs) & 1
    sclk = (data >> bus.sclk) & 1
    rises, falls = _edges(sclk)
    wins = _windows(cs, min_run)
    if not wins or len(rises) < 2 or len(falls) < 2:
        r.skip(group, "bus timing", "not enough edges in the capture")
        return
    # SCLK is parked low between frames, so its edges alternate rise then fall.
    if falls[0] < rises[0]:
        falls = falls[1:]
    n = min(len(rises), len(falls))
    # The worst pulse, not the typical one. A median hides a single runt among good pulses, and one runt is
    # enough to corrupt a transaction while still leaving 24 falling edges that decode perfectly.
    highs = (falls[:n] - rises[:n])
    lows = (rises[1:n] - falls[:n - 1])
    high = float(highs.min()) * dt_ns
    low = float(lows.min()) * dt_ns if len(lows) else float('nan')
    gaps = np.diff(falls)
    period = float(gaps[gaps <= 2 * np.median(gaps)].min()) * dt_ns

    per_window = [falls[(falls > s) & (falls < e)] for s, e in wins]
    css0 = min(int(f[0]) - s for f, (s, _) in zip(per_window, wins) if len(f)) * dt_ns
    def against(name: str, measured: float, limit: float) -> None:
        """PASS only when the measurement clears the limit outright.

        Allowing a whole sample interval of slack turns "tCH >= 8 ns" into "tCH >= -2 ns" at 100 MS/s. Landing
        within one sample of a limit is genuinely inconclusive, so say so rather than call it a pass.
        """
        label = f"{name} >= {limit:g} ns"
        if measured >= limit:
            r.check(group, label, True, f"{measured:.0f} ns")
        elif measured >= limit - dt_ns:
            r.skip(group, label, f"{measured:.0f} ns, within one {dt_ns:.0f} ns sample of the limit")
        else:
            r.check(group, label, False, f"{measured:.0f} ns")

    against("tSCLK", period, 20.0)
    against("tCH", high, 8.0)
    against("tCL", low, 8.0)
    against("tCSS0", css0, 8.0)
    if len(wins) > 1:
        cspw = min(b[0] - a[1] for a, b in zip(wins, wins[1:])) * dt_ns
        csf = min(b[0] - int(f[-1]) for f, b in zip(per_window, wins[1:]) if len(f)) * dt_ns
        against("tCSPW", cspw, 20.0)
        against("tCSF", csf, 100.0)
    # tDS (5 ns) and tDH (4.5 ns) are both below one sample interval here, so they are not measurable with
    # this instrument at all. They are met by construction -- the driver gives each half an SCLK period --
    # and the simulation model checks them against the data sheet on every edge.
    r.note(group, "tDS and tDH not measured", f"both limits are under one {dt_ns:.0f} ns sample")


# ------------------------------------------------------------------------------------------------ analog

def analog_checks(l: link.Max5725Link, d: dwf.AnalogDiscovery, r: Results, ref: int, csv_path: str,
                  plot_path: str | None, probes: dict[int, int], supply: float) -> None:
    group = "ANALOG"
    # Everything below is scaled from the selection the caller asked for, so any block that changes the
    # reference has to put it back -- otherwise the checks after it compare against the wrong full scale.
    vref = link.REF_VOLTAGE[ref]
    lsb = vref / 4096.0
    # The AD3's low gain stage spans +/-2.5 V about its offset, which a 4.096 V full scale overruns. Centre
    # the window on the range in use rather than dropping to the ten-times-coarser high range.
    base_offset = 2.0 if vref > 3.0 else 0.0
    d.configure_scope(volt_range=5.0, offset=base_offset)
    want = FULL_SCALE * lsb
    lo_ch, hi_ch = SCOPE_CHANNELS

    l.set_codes([0] * CHANNELS)
    time.sleep(0.05)
    zero_a, zero_b = d.read_dc(repeats=4)
    l.set_codes([FULL_SCALE] * CHANNELS)
    time.sleep(0.05)
    full_a, full_b = d.read_dc(repeats=4)
    for name, span in ((f"OUT{lo_ch}", full_a - zero_a), (f"OUT{hi_ch}", full_b - zero_b)):
        r.check(group, f"{name} full-scale span", abs(span - want) < 0.05 * want,
                f"{span:.4f} V, want ~{want:.4f}")

    # Sweep OUT0 up while OUT7 goes down, which also proves the two channels are independent.
    codes = list(range(128, 3969, 120))
    rows = []
    for c in codes:
        l.set_codes(codes_with(**{f"c{lo_ch}": c, f"c{hi_ch}": FULL_SCALE - c}))
        time.sleep(0.03)
        va, vb = d.read_dc(repeats=2)
        rows.append((c, va, vb))
    with open(csv_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow([f"code_out{lo_ch}", f"out{lo_ch}_volts", f"code_out{hi_ch}", f"out{hi_ch}_volts"])
        for c, va, vb in rows:
            w.writerow([c, f"{va:.6f}", FULL_SCALE - c, f"{vb:.6f}"])
    r.note(group, "sweep written", csv_path)

    x = np.array([c for c, _, _ in rows], dtype=float)
    for name, ys, xs in ((f"OUT{lo_ch}", np.array([va for _, va, _ in rows]), x),
                         (f"OUT{hi_ch}", np.array([vb for _, _, vb in rows]), float(FULL_SCALE) - x)):
        order = np.argsort(xs)
        xa, ya = xs[order], ys[order]
        slope, intercept = np.polyfit(xa, ya, 1)
        resid = ya - (slope * xa + intercept)
        r2 = 1.0 - resid.var() / ya.var()
        r.check(group, f"{name} slope", abs(slope - lsb) < 0.03 * lsb,
                f"{slope * 1e6:.2f} uV/LSB, want {lsb * 1e6:.2f}")
        r.check(group, f"{name} intercept", abs(intercept) < 0.030, f"{intercept * 1e3:+.1f} mV")
        r.check(group, f"{name} linearity R^2", r2 > 0.9999, f"{r2:.7f}")
        r.check(group, f"{name} monotonic", bool(np.all(np.diff(ya) > 0)),
                f"{int(np.sum(np.diff(ya) <= 0))} non-increasing steps")

    # Channel mapping for the two scope channels: move one word at a time and confirm only that output follows.
    l.set_codes([0] * CHANNELS)
    time.sleep(0.05)
    base_a, base_b = d.read_dc(repeats=2)
    for ch, other in ((lo_ch, hi_ch), (hi_ch, lo_ch)):
        l.set_codes(codes_with(**{f"c{ch}": FULL_SCALE}))
        time.sleep(0.05)
        va, vb = d.read_dc(repeats=2)
        moved, still = (va - base_a, vb - base_b) if ch == lo_ch else (vb - base_b, va - base_a)
        r.check(group, f"word {ch} drives OUT{ch} only", moved > 0.9 * want and abs(still) < 0.05,
                f"OUT{ch} {moved:+.3f} V, OUT{other} {still:+.3f} V")

    # These channels have only digital probes, so what is establishable is that each crosses its receiver's
    # threshold exactly once. That threshold is treated as an unknown constant: DwfParamDigitalThreshold reads
    # back as written but does not move the static DigitalIO path, which crosses at ~0.605 V regardless.
    def ramp_transitions(ch: int, bit: int, step: int = 16) -> tuple[list[int], list[int]]:
        """Walks the whole ramp and returns the codes at which the probe rose and at which it fell.

        Scanning to the end matters: stopping at the first rise would let a later glitch or fall pass unseen,
        which is precisely what "crosses exactly once" is supposed to rule out.
        """
        rises, falls, prev = [], [], 0
        for code in range(0, 4096, step):
            l.set_codes(codes_with(**{f"c{ch}": code}))
            time.sleep(0.010)
            now = (d.read_digital() >> bit) & 1
            if now and not prev:
                rises.append(code)
            elif prev and not now:
                falls.append(code)
            prev = now
        return rises, falls

    def level_at(ch: int, bit: int, code: int) -> int:
        l.set_codes(codes_with(**{f"c{ch}": code}))
        time.sleep(0.02)
        return (d.read_digital() >> bit) & 1

    crossings = {}
    for ch in DIGITAL_CHANNELS:
        bit = probes.get(ch)
        if bit is None:
            r.skip(group, f"OUT{ch} response", "no digital probe found")
            continue
        rises, falls = ramp_transitions(ch, bit)
        if not r.check(group, f"OUT{ch} crosses its threshold exactly once over the whole ramp",
                       len(rises) == 1 and len(falls) == 0,
                       f"{len(rises)} rise(s) at {rises}, {len(falls)} fall(s) at {falls}"):
            continue
        c = rises[0]
        crossings[ch] = c
        r.check(group, f"OUT{ch} crossing is a plausible receiver threshold",
                0.25 < c * lsb < 2.30, f"code {c} (~{c * lsb:.3f} V)")
        # A single sample could be luck; require the level to hold either side of the crossing.
        below, above = max(0, c - 250), min(FULL_SCALE, c + 250)
        low_level, high_level = level_at(ch, bit, below), level_at(ch, bit, above)
        r.check(group, f"OUT{ch} level holds either side of the crossing",
                (low_level == 0) and (high_level == 1),
                f"code {below} reads {low_level}, code {above} reads {high_level}")
    if len(crossings) > 1:
        # Every probe sees the same kind of receiver, so agreement cross-validates the channels.
        spread = max(crossings.values()) - min(crossings.values())
        r.check(group, "the digital-probed channels agree on the crossing", spread < 150,
                f"codes {sorted(crossings.values())}, spread {spread} ({spread * lsb * 1e3:.1f} mV)")
    l.set_codes([0] * CHANNELS)

    # Simultaneous update: drive the two scope channels to opposite rails in one frame and compare transitions.
    l.set_codes(codes_with(**{f"c{hi_ch}": FULL_SCALE}))
    time.sleep(0.1)
    dt = d.arm_edge_capture(level=0.5 * want, rate=2_000_000.0, buffer_size=8192, pre_fraction=0.25)
    timer = threading.Timer(0.2, lambda: l.set_codes(codes_with(**{f"c{lo_ch}": FULL_SCALE})))
    timer.start()
    try:
        ca, cb = d.fetch_capture(timeout=8.0)
        timer.join()
        mid_a = 0.5 * (ca.min() + ca.max())
        mid_b = 0.5 * (cb.min() + cb.max())
        rose, fell = ca > mid_a, cb < mid_b
        # argmax returns 0 for an all-false array, which would report a skew of zero -- a perfect score for a
        # capture in which neither channel moved at all. Require both crossings to exist before measuring.
        if not (rose.any() and fell.any() and (ca.max() - ca.min()) > 0.3 * want
                and (cb.max() - cb.min()) > 0.3 * want):
            r.check(group, f"OUT{lo_ch} and OUT{hi_ch} step together", False,
                    "no step captured on one or both channels, so the skew is not measurable")
        else:
            skew = abs(int(np.argmax(rose)) - int(np.argmax(fell))) * dt
            r.check(group, f"OUT{lo_ch} and OUT{hi_ch} step together", skew < 3e-6,
                    f"midpoints {skew * 1e6:.2f} us apart")
    except dwf.DwfError as exc:
        timer.join()
        r.skip(group, "simultaneous update", str(exc))

    # Reference selection: the span must track the reference the device was told to use.
    # Not named `ref`: that is the caller's selection, and shadowing it here would make the restore below
    # put back whichever reference this loop happened to end on.
    for sel, nominal in ((link.REF_2V048, 2.048), (link.REF_2V500, 2.500)):
        l.set_reference(sel)
        time.sleep(0.05)
        l.set_codes([0] * CHANNELS)
        time.sleep(0.05)
        z, _ = d.read_dc(repeats=2)
        l.set_codes(codes_with(**{f"c{lo_ch}": FULL_SCALE}))
        time.sleep(0.05)
        f, _ = d.read_dc(repeats=2)
        got = f - z
        expect = FULL_SCALE / 4096.0 * nominal
        r.check(group, f"span with {nominal:.3f} V reference", abs(got - expect) < 0.05 * expect,
                f"{got:.4f} V, want ~{expect:.4f}")
    l.set_reference(ref)                            # Back to the selection the rest of the checks assume

    # Per-channel signedness: the same word must land on a different voltage depending on its in_signed bit,
    # and a channel left unsigned must be unaffected by its neighbour's setting.
    l.set_signed_mask(1 << lo_ch)
    l.set_codes(codes_with(**{f"c{lo_ch}": 0x800, f"c{hi_ch}": 0x800}))
    time.sleep(0.06)
    va, vb = d.read_dc(repeats=2)
    r.check(group, "signed channel: most negative maps to zero scale", abs(va) < 0.03, f"OUT{lo_ch} {va:+.4f} V")
    r.check(group, "unsigned neighbour unaffected", abs(vb - 0x800 * lsb) < 0.03,
            f"OUT{hi_ch} {vb:+.4f} V, want ~{0x800 * lsb:.4f}")
    l.set_codes([0] * CHANNELS)
    time.sleep(0.06)
    va, vb = d.read_dc(repeats=2)
    r.check(group, "signed channel: zero maps to mid scale", abs(va - 0x800 * lsb) < 0.03,
            f"OUT{lo_ch} {va:+.4f} V, want ~{0x800 * lsb:.4f}")
    r.check(group, "unsigned channel: zero maps to zero scale", abs(vb) < 0.03, f"OUT{hi_ch} {vb:+.4f} V")
    l.set_signed_mask(0)
    l.set_codes([0] * CHANNELS)

    if supply >= 4.5:
        # VDD >= 4.5 V, so the 4.096 V reference is available. It exceeds the +/-2.5 V window of the low gain
        # stage, so shift the window up rather than dropping to the ten-times-coarser high range.
        try:
            d.configure_scope(volt_range=5.0, offset=2.0)
            l.set_reference(link.REF_4V096)
            time.sleep(0.05)
            l.set_codes([0] * CHANNELS)
            time.sleep(0.05)
            z, _ = d.read_dc(repeats=2)
            l.set_codes(codes_with(**{f"c{lo_ch}": FULL_SCALE}))
            time.sleep(0.05)
            f, _ = d.read_dc(repeats=2)
            expect = FULL_SCALE / 4096.0 * 4.096
            r.check(group, "span with 4.096 V reference", abs((f - z) - expect) < 0.05 * expect,
                    f"{f - z:.4f} V, want ~{expect:.4f}")
        finally:
            l.set_reference(ref)
            d.configure_scope(volt_range=5.0, offset=base_offset)
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
            yb = np.array([vb for _, _, vb in rows])
            ax.plot(xa, ya, ".-", label=f"OUT{lo_ch} (code ascending)")
            ax.plot(FULL_SCALE - xa, yb, ".-", label=f"OUT{hi_ch} (code descending)")
            ax.set_ylabel("output [V]")
            ax.set_title(f"MAX5725 transfer function, {vref:.3f} V reference")
            ax.grid(alpha=0.3)
            ax.legend()
            s, i0 = np.polyfit(xa, ya, 1)
            bx.plot(xa, (ya - (s * xa + i0)) * 1e3, ".-")
            bx.set_xlabel("DAC code")
            bx.set_ylabel(f"OUT{lo_ch} residual [mV]")
            bx.grid(alpha=0.3)
            fig.tight_layout()
            fig.savefig(plot_path, dpi=130)
            r.note(group, "plot written", plot_path)
        except Exception as exc:  # noqa: BLE001 - a missing plotting stack must not fail the measurement
            r.note(group, "plot skipped", str(exc))


# -------------------------------------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", default="max5725_transfer.csv")
    ap.add_argument("--plot", default="max5725_transfer.png")
    ap.add_argument("--no-plot", action="store_true")
    ap.add_argument("--reference", type=int, default=link.REF_2V500, choices=[1, 2, 3],
                    help="internal reference: 1=2.500V, 2=2.048V, 3=4.096V")
    ap.add_argument("--wire-only", action="store_true", help="skip the analog group even if the DAC responds")
    ap.add_argument("--supply", type=float, default=5.0, help="V+ output feeding the breakout's VDD")
    args = ap.parse_args()

    r = Results()
    print(f"WaveForms {dwf.version()}")
    with link.Max5725Link() as l:
        print(f"harness on {l.port}")
        l.ping()
        st = l.status()
        r.check("LINK", "MMCM locked", st["mmcm_locked"], str(st))
        r.check("LINK", "driver reports ready", st["dac_ready"], str(st))
        # Both of these raise on failure, which is a louder result than a FAIL row.
        l.ping()
        l.expect_nak(bytes([link.CMD_SET]) + bytes(2 * CHANNELS) + bytes([0x01]))
        r.note("LINK", "ping answered and a corrupt frame rejected")

        d = dwf.AnalogDiscovery("210415B9FB82")
        try:
            print(f"analog discovery {d.serial}")
            supply = d.set_positive_supply(args.supply)
            r.check("POWER", "V+ delivers the requested voltage", abs(supply - args.supply) < 0.15,
                    f"{supply:.3f} V, asked for {args.supply:.2f} V")
            d.set_digital_threshold(dwf.AD3_THRESHOLD_DEFAULT_MV)
            d.configure_digital_inputs()
            d.configure_scope(volt_range=5.0, offset=0.0)

            # The driver configures the device once, STARTUP_CYCLES after its own reset. If the DAC is powered
            # after the FPGA -- as it is here, since the breakout takes its supply from the instrument -- that
            # configuration is lost and the device sits in its power-on default of an external reference.
            # Re-running it is what a real system would achieve by sequencing power or holding rst.
            l.set_reference(args.reference)
            r.note("POWER", "device reconfigured after its supply came up")

            # That reconfiguration began with SW_RESET, which returns the outputs to the state the device's
            # M/Z pin selects. Which one it is depends on the JU1 shunt, so measure it rather than assume: the
            # assertable part is that it is one of the two the data sheet allows.
            time.sleep(0.05)
            vref = link.REF_VOLTAGE[args.reference]
            rst_a, rst_b = d.read_dc(repeats=4)
            # Reported rather than asserted: a dead, unpowered or unseated device also reads 0 V on both
            # channels, so "zero scale" here would be a pass that means nothing. The responsiveness check
            # below is the one that can actually fail.
            zero_scale = abs(rst_a) < 0.05 and abs(rst_b) < 0.05
            mid_scale = abs(rst_a - 0.5 * vref) < 0.05 and abs(rst_b - 0.5 * vref) < 0.05
            r.note("POWER", "output after SW_RESET",
                   f"OUT0 {rst_a:.4f} V, OUT7 {rst_b:.4f} V -- "
                   f"{'zero scale, M/Z low' if zero_scale else 'mid scale, M/Z high' if mid_scale else 'neither'}")

            probes = discover_output_probes(l, d, r)
            bus = discover_bus(l, d, r, used=set(probes.values()))
            if bus is not None:
                wire_checks(l, d, r, bus, args.reference)
            else:
                r.skip("WIRE", "every decode check", "the SPI bus probes could not be identified")
            l.set_signed_mask(0)

            # Nothing but the outputs can confirm the device executed anything, so gate the analog group on
            # the cheapest evidence. Quarter scale, not mid scale: this board straps M/Z high, so an entirely
            # unresponsive device sits at mid scale and commanding it would pass while proving nothing.
            l.set_codes(codes_with(c0=0x400, c7=0x400))
            time.sleep(0.06)
            va, vb = d.read_dc(repeats=2)
            want_q = 0.25 * vref
            responding = abs(va - want_q) < 0.10 and abs(vb - want_q) < 0.10
            r.check("LINK", "the DAC responds to a commanded code", responding,
                    f"quarter scale commanded, OUT0 {va:.4f} V, OUT7 {vb:.4f} V, want ~{want_q:.4f}")

            if args.wire_only or not responding:
                r.skip("ANALOG", "every analog check",
                       "the DAC is not following commanded codes -- if the wire group passed, the bus is "
                       "provably correct at its pins, so this is a board-side condition (power, reference or "
                       "seating), not a driver fault")
            else:
                analog_checks(l, d, r, args.reference, args.csv,
                              None if args.no_plot else args.plot, probes, supply)
            # A skip does not count as a failure, so a run in which everything skipped would otherwise
            # report success while verifying nothing: build at a rate the analyser cannot decode, pass
            # --wire-only, and every real check is skipped. Require that the group this run exists to
            # exercise actually produced results.
            if args.wire_only:
                ok = r.passes("WIRE") > 0
                r.check("RESULT", "the wire group verified frames", ok,
                        "" if ok else "nothing was decoded, so this run proves nothing about the driver")
            else:
                ok = r.passes("ANALOG") > 0
                r.check("RESULT", "the analog group ran", ok,
                        "" if ok else "no analog check produced a result")
        finally:
            d.close()
    return r.report()


if __name__ == "__main__":
    sys.exit(main())
