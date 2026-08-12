"""Thin ctypes binding to the Digilent WaveForms SDK, covering just what the max5715 bench test needs.

Deliberately not pydwf: the packaged release predates the installed libdwf and its typed DwfDeviceParameter
enumeration has no DigitalThreshold member, so the AD3's input threshold cannot be set without reaching around
its own API. The declarations below are transcribed from /usr/include/digilent/waveforms/dwf.h.
"""

from __future__ import annotations

import ctypes
import time

import numpy as np

_dwf = ctypes.cdll.LoadLibrary("libdwf.so")

# Constants from dwf.h.
ENUMFILTER_ALL = 0
ACQMODE_SINGLE = 0
FILTER_DECIMATE = 0
FILTER_AVERAGE = 1
STATE_DONE = 2
TRIGSRC_NONE = 0
TRIGSRC_DETECTOR_ANALOG_IN = 2
TRIGSRC_DETECTOR_DIGITAL_IN = 3
TRIGTYPE_EDGE = 0
SLOPE_RISE = 0
SLOPE_FALL = 1
PARAM_DIGITAL_THRESHOLD = 15  # millivolts; the AD3 offers exactly 1400 (default) and 600
PARAM_ON_CLOSE = 4            # 0 continue, 1 stop, 2 shutdown

AD3_THRESHOLD_DEFAULT_MV = 1400
AD3_THRESHOLD_LOW_MV = 600


class DwfError(RuntimeError):
    pass


def _check(ok: int, what: str) -> None:
    if ok:
        return
    buf = ctypes.create_string_buffer(512)
    _dwf.FDwfGetLastErrorMsg(buf)
    raise DwfError(f"{what}: {buf.value.decode(errors='replace').strip()}")


def version() -> str:
    buf = ctypes.create_string_buffer(32)
    _check(_dwf.FDwfGetVersion(buf), "FDwfGetVersion")
    return buf.value.decode()


class AnalogDiscovery:
    """One open Analog Discovery device: two scope channels plus static digital pin reads."""

    def __init__(self, serial_number: str | None = None) -> None:
        count = ctypes.c_int()
        _check(_dwf.FDwfEnum(ctypes.c_int(ENUMFILTER_ALL), ctypes.byref(count)), "FDwfEnum")
        index = -1
        found = []
        for i in range(count.value):
            sn = ctypes.create_string_buffer(32)
            _check(_dwf.FDwfEnumSN(ctypes.c_int(i), sn), "FDwfEnumSN")
            text = sn.value.decode(errors="replace")
            found.append(text)
            if serial_number is None or serial_number in text:
                index = i
                break
        if index < 0:
            raise DwfError(f"no device matching {serial_number!r}; enumerated: {found}")
        self.serial = found[-1]
        self.hdwf = ctypes.c_int()
        _check(_dwf.FDwfDeviceOpen(ctypes.c_int(index), ctypes.byref(self.hdwf)), "FDwfDeviceOpen")
        # Apply settings explicitly rather than on every parameter write.
        _check(_dwf.FDwfDeviceAutoConfigureSet(self.hdwf, ctypes.c_int(0)), "FDwfDeviceAutoConfigureSet")
        self._range = None

    def close(self) -> None:
        """Closes this handle only. FDwfDeviceCloseAll would take down every other open device too."""
        if self.hdwf.value:
            _dwf.FDwfDeviceClose(self.hdwf)
            self.hdwf.value = 0

    def __enter__(self) -> "AnalogDiscovery":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # ---------------------------------------------------------------- supply

    def set_positive_supply(self, volts: float, keep_on_close: bool = True) -> float:
        """Enables the V+ programmable supply, which powers the MAX5715BOB. Returns the voltage read back.

        The breakout is not fed from the Pmod connector, so without this the device sits unpowered: its
        interface pins are driven, but it executes nothing and every output stays at zero.
        """
        if not 0.5 <= volts <= 5.0:
            raise ValueError(f"V+ is adjustable over 0.5..5 V, not {volts}")
        h = self.hdwf
        if keep_on_close:
            # Leave the supply running when the handle closes, so the board keeps its power between runs.
            _check(_dwf.FDwfParamSet(ctypes.c_int(PARAM_ON_CLOSE), ctypes.c_int(0)), "ParamSet(OnClose)")
            _check(_dwf.FDwfDeviceParamSet(h, ctypes.c_int(PARAM_ON_CLOSE), ctypes.c_int(0)),
                   "DeviceParamSet(OnClose)")
        _check(_dwf.FDwfAnalogIOChannelNodeSet(h, ctypes.c_int(0), ctypes.c_int(0), ctypes.c_double(1)),
               "AnalogIOChannelNodeSet(V+ enable)")
        _check(_dwf.FDwfAnalogIOChannelNodeSet(h, ctypes.c_int(0), ctypes.c_int(1), ctypes.c_double(volts)),
               "AnalogIOChannelNodeSet(V+ voltage)")
        _check(_dwf.FDwfAnalogIOEnableSet(h, ctypes.c_int(1)), "AnalogIOEnableSet")
        # Auto-configure is off for this handle, so AnalogIO settings have to be pushed explicitly.
        _check(_dwf.FDwfAnalogIOConfigure(h), "AnalogIOConfigure")
        time.sleep(0.3)
        return self.positive_supply_status()

    def positive_supply_status(self) -> float:
        """The V+ voltage the device reports it is actually delivering."""
        _check(_dwf.FDwfAnalogIOStatus(self.hdwf), "AnalogIOStatus")
        v = ctypes.c_double()
        _check(_dwf.FDwfAnalogIOChannelNodeStatus(self.hdwf, ctypes.c_int(0), ctypes.c_int(1),
                                                  ctypes.byref(v)), "AnalogIOChannelNodeStatus")
        return float(v.value)

    # ----------------------------------------------------------------- scope

    def configure_scope(self, volt_range: float = 5.0, offset: float = 0.0,
                        rate: float = 100_000.0, buffer_size: int = 8192,
                        average: bool = True) -> None:
        """Enables both channels on the low gain stage.

        A 5 V range selects the AD3's low range, whose 0.336 mV resolution and +/-10 mV +/-0.5 % accuracy beat
        the high range by a factor of ten. A 0..2.5 V DAC output fits without any offset.
        """
        h = self.hdwf
        for ch in (0, 1):
            _check(_dwf.FDwfAnalogInChannelEnableSet(h, ctypes.c_int(ch), ctypes.c_int(1)), "ChannelEnableSet")
            _check(_dwf.FDwfAnalogInChannelRangeSet(h, ctypes.c_int(ch), ctypes.c_double(volt_range)),
                   "ChannelRangeSet")
            _check(_dwf.FDwfAnalogInChannelOffsetSet(h, ctypes.c_int(ch), ctypes.c_double(offset)),
                   "ChannelOffsetSet")
            _check(_dwf.FDwfAnalogInChannelFilterSet(
                h, ctypes.c_int(ch), ctypes.c_int(FILTER_AVERAGE if average else FILTER_DECIMATE)),
                "ChannelFilterSet")
        _check(_dwf.FDwfAnalogInAcquisitionModeSet(h, ctypes.c_int(ACQMODE_SINGLE)), "AcquisitionModeSet")
        _check(_dwf.FDwfAnalogInFrequencySet(h, ctypes.c_double(rate)), "FrequencySet")
        _check(_dwf.FDwfAnalogInBufferSizeSet(h, ctypes.c_int(buffer_size)), "BufferSizeSet")
        _check(_dwf.FDwfAnalogInTriggerSourceSet(h, ctypes.c_ubyte(TRIGSRC_NONE)), "TriggerSourceSet")
        # arm_edge_capture() disables the auto-trigger; without restoring it an untriggered acquisition would
        # wait for an edge that never comes and time out.
        _check(_dwf.FDwfAnalogInTriggerAutoTimeoutSet(h, ctypes.c_double(1.0)), "TriggerAutoTimeoutSet")
        _check(_dwf.FDwfAnalogInConfigure(h, ctypes.c_int(1), ctypes.c_int(0)), "Configure")
        self._buffer_size = buffer_size
        if self._range != (volt_range, offset):
            # The input stage needs time to settle after a range or offset change.
            time.sleep(2.0)
            self._range = (volt_range, offset)

    def _acquire(self) -> tuple[np.ndarray, np.ndarray]:
        h = self.hdwf
        # Force an untriggered acquisition. arm_edge_capture() leaves a trigger armed and the auto-trigger
        # disabled, and a plain DC read must not inherit that or it waits for an edge that never arrives.
        _check(_dwf.FDwfAnalogInTriggerSourceSet(h, ctypes.c_ubyte(TRIGSRC_NONE)), "TriggerSourceSet")
        _check(_dwf.FDwfAnalogInTriggerAutoTimeoutSet(h, ctypes.c_double(1.0)), "TriggerAutoTimeoutSet")
        _check(_dwf.FDwfAnalogInConfigure(h, ctypes.c_int(1), ctypes.c_int(1)), "Configure(start)")
        state = ctypes.c_ubyte()
        deadline = time.monotonic() + 5.0
        while True:
            _check(_dwf.FDwfAnalogInStatus(h, ctypes.c_int(1), ctypes.byref(state)), "AnalogInStatus")
            if state.value == STATE_DONE:
                break
            if time.monotonic() > deadline:
                raise DwfError("analog acquisition did not complete")
            time.sleep(0.001)
        out = []
        for ch in (0, 1):
            buf = (ctypes.c_double * self._buffer_size)()
            _check(_dwf.FDwfAnalogInStatusData(h, ctypes.c_int(ch), buf, ctypes.c_int(self._buffer_size)),
                   "StatusData")
            out.append(np.ctypeslib.as_array(buf).copy())
        return out[0], out[1]

    def read_dc(self, repeats: int = 1) -> tuple[float, float]:
        """Mean voltage of both channels. Averaging beats down noise but not gain or offset error."""
        acc = np.zeros(2)
        for _ in range(repeats):
            a, b = self._acquire()
            acc += (a.mean(), b.mean())
        return float(acc[0] / repeats), float(acc[1] / repeats)

    def arm_edge_capture(self, level: float, rate: float = 2_000_000.0, buffer_size: int = 8192,
                         pre_fraction: float = 0.25) -> float:
        """Arms a single capture triggered by channel 1 rising through ``level``. Returns the sample interval.

        Arm first, then cause the event, then call fetch_capture().
        """
        h = self.hdwf
        _check(_dwf.FDwfAnalogInFrequencySet(h, ctypes.c_double(rate)), "FrequencySet")
        _check(_dwf.FDwfAnalogInBufferSizeSet(h, ctypes.c_int(buffer_size)), "BufferSizeSet")
        self._buffer_size = buffer_size
        _check(_dwf.FDwfAnalogInTriggerSourceSet(h, ctypes.c_ubyte(TRIGSRC_DETECTOR_ANALOG_IN)),
               "TriggerSourceSet")
        _check(_dwf.FDwfAnalogInTriggerTypeSet(h, ctypes.c_int(TRIGTYPE_EDGE)), "TriggerTypeSet")
        _check(_dwf.FDwfAnalogInTriggerChannelSet(h, ctypes.c_int(0)), "TriggerChannelSet")
        _check(_dwf.FDwfAnalogInTriggerLevelSet(h, ctypes.c_double(level)), "TriggerLevelSet")
        _check(_dwf.FDwfAnalogInTriggerConditionSet(h, ctypes.c_int(SLOPE_RISE)), "TriggerConditionSet")
        _check(_dwf.FDwfAnalogInTriggerHysteresisSet(h, ctypes.c_double(0.05)), "TriggerHysteresisSet")
        # Disable the auto-trigger, otherwise a "triggered" capture may quietly fire on its own.
        _check(_dwf.FDwfAnalogInTriggerAutoTimeoutSet(h, ctypes.c_double(0.0)), "TriggerAutoTimeoutSet")
        position = (0.5 - pre_fraction) * buffer_size / rate
        _check(_dwf.FDwfAnalogInTriggerPositionSet(h, ctypes.c_double(position)), "TriggerPositionSet")
        _check(_dwf.FDwfAnalogInConfigure(h, ctypes.c_int(1), ctypes.c_int(1)), "Configure(arm)")
        time.sleep(0.05)                # Let the acquisition reach the armed state before the event happens
        return 1.0 / rate

    def fetch_capture(self, timeout: float = 5.0) -> tuple[np.ndarray, np.ndarray]:
        h = self.hdwf
        state = ctypes.c_ubyte()
        deadline = time.monotonic() + timeout
        while True:
            _check(_dwf.FDwfAnalogInStatus(h, ctypes.c_int(1), ctypes.byref(state)), "AnalogInStatus")
            if state.value == STATE_DONE:
                break
            if time.monotonic() > deadline:
                raise DwfError("no trigger within the timeout")
            time.sleep(0.001)
        out = []
        for ch in (0, 1):
            buf = (ctypes.c_double * self._buffer_size)()
            _check(_dwf.FDwfAnalogInStatusData(h, ctypes.c_int(ch), buf, ctypes.c_int(self._buffer_size)),
                   "StatusData")
            out.append(np.ctypeslib.as_array(buf).copy())
        return out[0], out[1]

    # --------------------------------------------------------------- digital

    def arm_logic_capture(self, rate: float = 100e6, samples: int = 4096,
                          fall_mask: int = 0, rise_mask: int = 0, prefill: int = 32) -> float:
        """Arms the logic analyser on a digital edge. Returns the achieved sample rate.

        Arm first, then cause the event, then call fetch_logic().

        The requested buffer size is clamped to what the instrument actually offers, and the trigger position
        is then derived from the granted size. Asking for more silently gets you less, and a trigger position
        computed from the larger figure would keep a window that far past the trigger instead of around it --
        which reads as a capture full of idle levels rather than as an error.
        """
        h = self.hdwf
        base = ctypes.c_double()
        _check(_dwf.FDwfDigitalInInternalClockInfo(h, ctypes.byref(base)), "DigitalInInternalClockInfo")
        div = max(1, int(round(base.value / rate)))
        _check(_dwf.FDwfDigitalInDividerSet(h, ctypes.c_uint(div)), "DigitalInDividerSet")
        _check(_dwf.FDwfDigitalInSampleFormatSet(h, ctypes.c_int(16)), "DigitalInSampleFormatSet")
        largest = ctypes.c_int()
        _check(_dwf.FDwfDigitalInBufferSizeInfo(h, ctypes.byref(largest)), "DigitalInBufferSizeInfo")
        _check(_dwf.FDwfDigitalInBufferSizeSet(h, ctypes.c_int(min(samples, largest.value))),
               "DigitalInBufferSizeSet")
        granted = ctypes.c_int()
        _check(_dwf.FDwfDigitalInBufferSizeGet(h, ctypes.byref(granted)), "DigitalInBufferSizeGet")
        samples = int(granted.value)
        _check(_dwf.FDwfDigitalInAcquisitionModeSet(h, ctypes.c_int(ACQMODE_SINGLE)),
               "DigitalInAcquisitionModeSet")
        if fall_mask or rise_mask:
            _check(_dwf.FDwfDigitalInTriggerSourceSet(h, ctypes.c_ubyte(TRIGSRC_DETECTOR_DIGITAL_IN)),
                   "DigitalInTriggerSourceSet")
            _check(_dwf.FDwfDigitalInTriggerSet(h, ctypes.c_uint(0), ctypes.c_uint(0),
                                                ctypes.c_uint(rise_mask), ctypes.c_uint(fall_mask)),
                   "DigitalInTriggerSet")
            _check(_dwf.FDwfDigitalInTriggerPositionSet(h, ctypes.c_uint(samples - min(prefill, samples))),
                   "DigitalInTriggerPositionSet")
            _check(_dwf.FDwfDigitalInTriggerPrefillSet(h, ctypes.c_uint(prefill)),
                   "DigitalInTriggerPrefillSet")
            _check(_dwf.FDwfDigitalInTriggerAutoTimeoutSet(h, ctypes.c_double(0.0)),
                   "DigitalInTriggerAutoTimeoutSet")
        else:
            _check(_dwf.FDwfDigitalInTriggerSourceSet(h, ctypes.c_ubyte(TRIGSRC_NONE)),
                   "DigitalInTriggerSourceSet")
        _check(_dwf.FDwfDigitalInConfigure(h, ctypes.c_int(1), ctypes.c_int(1)), "DigitalInConfigure")
        self._logic_samples = samples
        return base.value / div

    def fetch_logic(self, timeout: float = 5.0) -> np.ndarray:
        """The captured samples as uint16, one bit per DIO channel."""
        h = self.hdwf
        state = ctypes.c_ubyte()
        deadline = time.monotonic() + timeout
        while True:
            _check(_dwf.FDwfDigitalInStatus(h, ctypes.c_int(1), ctypes.byref(state)), "DigitalInStatus")
            if state.value == STATE_DONE:
                break
            if time.monotonic() > deadline:
                raise DwfError("no digital trigger within the timeout")
            time.sleep(0.001)
        buf = (ctypes.c_uint16 * self._logic_samples)()
        _check(_dwf.FDwfDigitalInStatusData(h, buf, ctypes.c_int(self._logic_samples * 2)),
               "DigitalInStatusData")
        return np.ctypeslib.as_array(buf).copy()

    def set_digital_threshold(self, millivolts: int) -> None:
        """The AD3's receiver threshold; only 1400 mV (default) and 600 mV are offered."""
        _check(_dwf.FDwfDeviceParamSet(self.hdwf, ctypes.c_int(PARAM_DIGITAL_THRESHOLD),
                                      ctypes.c_int(int(millivolts))), "DeviceParamSet(threshold)")

    def configure_digital_inputs(self) -> None:
        """Makes every DIO pin an input so the static levels can be read back."""
        _check(_dwf.FDwfDigitalIOOutputEnableSet(self.hdwf, ctypes.c_uint(0)), "DigitalIOOutputEnableSet")
        _check(_dwf.FDwfDigitalIOConfigure(self.hdwf), "DigitalIOConfigure")

    def read_digital(self) -> int:
        """Bit mask of the current DIO pin levels."""
        _check(_dwf.FDwfDigitalIOStatus(self.hdwf), "DigitalIOStatus")
        pins = ctypes.c_uint()
        _check(_dwf.FDwfDigitalIOInputStatus(self.hdwf, ctypes.byref(pins)), "DigitalIOInputStatus")
        return int(pins.value)
