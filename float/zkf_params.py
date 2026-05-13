#!/usr/bin/env python3

from dataclasses import dataclass
from fractions import Fraction


@dataclass(frozen=True)
class ZkfParams:
    """
    Exact key parameters of the Zubax Kulibin float format.
    """

    wexp: int
    """Exponent bit width."""
    wman: int
    """Significand bit width; represented with one fewer bit."""

    def __post_init__(self) -> None:
        if self.wexp < 1 or self.wman < 2:
            raise ValueError

    @property
    def wfrac(self) -> int:
        """Stored fraction width."""
        return self.wman - 1

    @property
    def wfull(self) -> int:
        """Total packed width: 1 sign + wexp + wfrac."""
        return 1 + self.wexp + self.wfrac

    @property
    def bias(self) -> int:
        return (1 << (self.wexp - 1)) - 1

    @property
    def min(self) -> Fraction:
        """Smallest representable positive magnitude (no subnormals)."""
        return self._pow2(1 - self.bias)

    @property
    def max(self) -> Fraction:
        """Largest finite magnitude."""
        max_exp = (1 << self.wexp) - 1 - self.bias
        return (Fraction(2) - self._pow2(-self.wfrac)) * self._pow2(max_exp)

    @property
    def epsilon(self) -> Fraction:
        """Gap between 1.0 and the next representable value above it."""
        return self._pow2(-self.wfrac)

    @staticmethod
    def _pow2(k: int) -> Fraction:
        return Fraction(1 << k, 1) if k >= 0 else Fraction(1, 1 << -k)


if __name__ == "__main__":
    import sys
    wexp, wman = map(int, (sys.argv[1], sys.argv[2]))
    p = ZkfParams(wexp, wman)
    print(f"WEXP={p.wexp} WMAN={p.wman} WFRAC={p.wfrac} WFULL={p.wfull} BIAS={p.bias}")
    print(f"min_normal = {p.min} ≈ {float(p.min):.3e}")
    print(f"max_value  = {p.max} ≈ {float(p.max):.3e}")
    print(f"epsilon    = {p.epsilon} ≈ {float(p.epsilon):.3e}")

    print("s" + "e" * p.wexp + "f" * p.wfrac)
    print(("0123456789" * ((p.wfull + 10)//10))[:p.wfull][::-1])
    print("".join((f"{x}" * 10) for x in range(10))[:p.wfull][::-1])
