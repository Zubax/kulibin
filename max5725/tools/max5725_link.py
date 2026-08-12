"""Host side of the serial link to the max5725 bench harness running on the Arty S7.

The framing is defined in ../fpga/arty_s7_max5725_top.v. Every command is answered by exactly one byte, so the
link is strictly request/response and the host never has to guess whether a command took effect.
"""

from __future__ import annotations

import glob
import time

import serial

ARTY_SERIAL = "210352A895A4"

CMD_SET = 0xA5
CMD_REF = 0xB4
CMD_PING = 0x3F
CMD_STAT = 0x52
CMD_SGN = 0xC3

RSP_ACK = 0x5A
RSP_NAK = 0xEE
RSP_PONG = 0xA7

REF_EXTERNAL = 0b00
REF_2V500 = 0b01
REF_2V048 = 0b10
REF_4V096 = 0b11

REF_VOLTAGE = {REF_2V500: 2.500, REF_2V048: 2.048, REF_4V096: 4.096}

CODE_BITS = 12
CODE_MAX = (1 << CODE_BITS) - 1
CHANNELS = 8
CHANNEL_NAMES = tuple(f"OUT{i}" for i in range(CHANNELS))


class ProtocolError(RuntimeError):
    pass


def find_port(serial_number: str = ARTY_SERIAL) -> str:
    """Locates the FT2232 UART channel. Channel A is JTAG, so the UART is the ``-if01`` interface."""
    for pattern in (
        f"/dev/serial/by-id/*{serial_number}*-if01*",
        f"/dev/serial/by-id/*{serial_number}*",
    ):
        matches = sorted(glob.glob(pattern))
        if matches:
            return matches[-1]
    raise RuntimeError(
        f"no serial port found for Digilent device {serial_number}; "
        "is the board connected, and is interface 1 still bound to ftdi_sio?"
    )


def _checksum(payload: bytes) -> int:
    acc = 0
    for byte in payload:
        acc ^= byte
    return acc


class Max5725Link:
    """Commands the eight DAC channels and the reference selection over the board's USB-UART."""

    def __init__(self, port: str | None = None, baud: int = 115_200, timeout: float = 1.0) -> None:
        self.port = port or find_port()
        self.ser = serial.Serial(self.port, baud, timeout=timeout)
        time.sleep(0.05)
        self.ser.reset_input_buffer()

    def close(self) -> None:
        self.ser.close()

    def __enter__(self) -> "Max5725Link":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _transact(self, frame: bytes, expect: int, what: str) -> None:
        self.ser.reset_input_buffer()
        self.ser.write(frame)
        self.ser.flush()
        reply = self.ser.read(1)
        if not reply:
            raise ProtocolError(f"{what}: no reply within {self.ser.timeout} s (frame {frame.hex()})")
        if reply[0] != expect:
            name = {RSP_ACK: "ACK", RSP_NAK: "NAK", RSP_PONG: "PONG"}.get(reply[0], "?")
            raise ProtocolError(f"{what}: expected 0x{expect:02X}, got 0x{reply[0]:02X} ({name})")

    def ping(self) -> None:
        """Checks that the harness is alive and the link is synchronised."""
        self._transact(bytes([CMD_PING]), RSP_PONG, "ping")

    def resync(self) -> None:
        """Recovers the link if a partial frame was ever left in flight."""
        self.ser.reset_input_buffer()
        # The harness abandons an unfinished frame after a short silence, so a pause then a ping is enough.
        time.sleep(0.05)
        self.ping()

    def status(self) -> dict:
        """Reads the harness telltales.

        The MAX5725 has no RDY pin and its DOUT is not wired, so unlike the max5715 bench this count is the
        driver's own: samples it accepted, not frames the device confirmed executing. Execution is established
        instead by capturing the bus with the logic analyser -- see hw_test.py.
        """
        self.ser.reset_input_buffer()
        self.ser.write(bytes([CMD_STAT]))
        self.ser.flush()
        reply = self.ser.read(3)
        if len(reply) != 3:
            raise ProtocolError(f"status: expected 3 bytes, got {reply.hex()}")
        flags = reply[2]
        return {
            "samples_accepted": (reply[0] << 8) | reply[1],
            "frame_ok": bool(flags & 0x01),
            "dac_ready": bool(flags & 0x02),
            "mmcm_locked": bool(flags & 0x04),
        }

    def set_codes(self, codes) -> None:
        """Sets all eight DAC codes and updates every output simultaneously."""
        codes = list(codes)
        if len(codes) != CHANNELS:
            raise ValueError(f"expected {CHANNELS} codes, got {len(codes)}")
        payload = bytearray([CMD_SET])
        for code in codes:
            code = int(code)
            if not 0 <= code <= CODE_MAX:
                raise ValueError(f"code {code} out of range 0..{CODE_MAX}")
            payload += bytes([(code >> 8) & 0x0F, code & 0xFF])
        payload.append(_checksum(payload))
        self._transact(bytes(payload), RSP_ACK, f"set_codes({codes})")

    def set_signed_mask(self, mask: int) -> None:
        """One bit per channel: 1 means that channel's word is two's complement and gets the half-range bias."""
        if not 0 <= mask <= 0xFF:
            raise ValueError(f"mask {mask} does not fit eight channels")
        payload = bytearray([CMD_SGN, mask])
        payload.append(_checksum(payload))
        self._transact(bytes(payload), RSP_ACK, f"set_signed_mask(0b{mask:08b})")

    def set_reference(self, ref: int) -> None:
        """Re-runs device configuration with a new reference selection; takes about a millisecond."""
        if ref not in (REF_EXTERNAL, REF_2V500, REF_2V048, REF_4V096):
            raise ValueError(f"bad reference selection {ref}")
        payload = bytearray([CMD_REF, ref])
        payload.append(_checksum(payload))
        self._transact(bytes(payload), RSP_ACK, f"set_reference({ref})")
        time.sleep(0.01)  # Covers the four configuration frames and the reference settling

    def expect_nak(self, frame: bytes) -> None:
        """Sends a deliberately malformed frame and requires it to be rejected."""
        self._transact(frame, RSP_NAK, "malformed frame")
