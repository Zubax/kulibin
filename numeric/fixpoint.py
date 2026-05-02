#!/usr/bin/env python3
"""
Utilities for fixed point conversion.
We could use qformatpy but I thought it's not worth an extra dependency.

For string representation we use binary instead of hexadecimal because it is bit-level-granular,
which helps avoid ambiguities with the length of negatives (hex requires padding up to 4 bits).

See also:
- https://chummersone.github.io/qformat.html#arithmetic
"""

import math


def to_fixpoint(q: tuple[int, int], x: float, /) -> int:
    """
    Convert a real number into a Q-format fixed-point integer with two's complement encoding.
    Raises ValueError if the number cannot be represented in the specified Q-format.
    Range: [-2**(q[0]-1), 2**(q[0]-1) - 2**(-q[1])]
    """
    w_int_with_sign, w_frac = map(int, q)
    if w_int_with_sign < 1 or w_frac < 0:
        raise ValueError
    x = float(x)
    if not math.isfinite(x):
        raise ValueError(f"Cannot convert a non-finite real {x} into fixed point")
    scale = 1 << w_frac
    w = w_int_with_sign + w_frac
    min_int = -(1 << (w - 1))
    max_int =  (1 << (w - 1)) - 1
    n = int(round(x * scale))
    if n < min_int or n > max_int:
        raise OverflowError(f"{x} does not fit q{w_int_with_sign}.{w_frac}")
    return n



def from_fixpoint(q: tuple[int, int], x: int | str, /) -> float:
    """
    Converts x from fixpoint to float. Accepts native integers or binary strings.
    """
    w_int_with_sign, w_frac = map(int, q)
    if w_int_with_sign < 1 or w_frac < 0:
        raise ValueError
    w = w_int_with_sign + w_frac
    if isinstance(x, str):
        s = x.strip().replace("_", "")
        if not s or any(c not in "01" for c in s):
            raise ValueError(f"Invalid binary string for fixed-point value: {x!r}")
        if len(s) != w:
            raise ValueError(f"Bit count mismatch: expected {w} bits, got this: {x!r}")
        u = int(s, 2)
        if u & (1 << (w - 1)):
            x = u - (1 << w)
        else:
            x = u
    if not isinstance(x, int):
        raise TypeError("x must be int or bin string")
    min_int = -(1 << (w - 1))
    max_int =  (1 << (w - 1)) - 1
    if x < min_int or x > max_int:
        raise OverflowError(f"{x} does not fit q{w_int_with_sign}.{w_frac}")
    return x / float(1 << w_frac)


def to_fixpoint_bin(q: tuple[int, int], x: float, /) -> str:
    """
    Like to_fixpoint() but the result is represented as a fixed-length binary string.
    The number of characters equals the total number of bits in the q-format.

    Binary works better than hex for signed numbers because we don't have to leave padding MSB zero bits,
    and we can't use sign-extension because it would result in the excess bit length numbers,
    causing some synthesizers (Synplify Pro in particular) to just flat out ignore the entire array
    with a warning.
    """
    w = sum(map(int, q))
    n = to_fixpoint(q, x)
    return format(n & ((1 << w) - 1), f"0{w}b")


assert to_fixpoint_bin((8, 8), -12.34) == '1111001110101001'
assert to_fixpoint_bin((8, 8), +12.34) == '0000110001010111'


def main():
    import sys

    if len(sys.argv) < 4:
        print("Usage:", sys.argv[0], "q-intg", "q-frac", "expr...", file=sys.stderr)
        exit()

    _, Q_intg, Q_frac, *exprs = sys.argv
    q = int(Q_intg), int(Q_frac)
    print(f"// q{Q_intg}.{Q_frac}")
    for expr in exprs:
        # Convert the number to fixpoint Q-format.
        number = float(eval(expr))
        fixp = to_fixpoint_bin(q, number)

        # Estimate the error.
        e_abs = abs(number - from_fixpoint(q, fixp))
        e_rel = e_abs / abs(number)
        e_str = "exact" if e_abs < 1e-9 else f"{e_abs=:e} e_rel={100*e_rel:.3f}%"

        print(f"{fixp}  // {number:+e} = {expr}; {e_str}")


if __name__ == "__main__":
    main()
