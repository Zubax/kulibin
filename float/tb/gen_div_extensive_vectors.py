#!/usr/bin/env python3
"""Generate committed golden vectors for zkf_div_extensive_tb.v.

The smaller custom formats use an exact integer/Fraction oracle.  The
binary32-like and binary64-like formats use NumPy for the finite arithmetic
rounding, with ZKF canonicalization for zeros, infinities, and unsupported
subnormal/NaN encodings.

Finite exact half-ulp ties are not representable as a quotient of two normal
same-precision significands: a guard-only tie requires one more factor of two
in the reduced denominator than the divisor significand can provide.  The
directed rounding cases therefore cover the reachable divider GRS boundaries:
guard+round increment and both sticky sources.
"""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
import argparse
import sys

import numpy as np


@dataclass(frozen=True)
class Format:
    wexp: int
    wman: int

    @property
    def wfrac(self) -> int:
        return self.wman - 1

    @property
    def wfull(self) -> int:
        return self.wexp + self.wman

    @property
    def bias(self) -> int:
        return (1 << (self.wexp - 1)) - 1

    @property
    def exp_inf(self) -> int:
        return (1 << self.wexp) - 1

    @property
    def exp_max_finite(self) -> int:
        return self.exp_inf - 1

    @property
    def frac_mask(self) -> int:
        return (1 << self.wfrac) - 1

    @property
    def sign_shift(self) -> int:
        return self.wexp + self.wfrac

    @property
    def min_exp_unbiased(self) -> int:
        return 1 - self.bias

    @property
    def max_exp_unbiased(self) -> int:
        return self.exp_max_finite - self.bias


@dataclass(frozen=True)
class Config:
    name: str
    fmt: Format
    count: int
    oracle: str
    seed: int


@dataclass(frozen=True)
class Observation:
    high: bool
    significand_lsb: int
    guard: int
    round_bit: int
    produced_tail: bool
    final_rem_sticky: bool

    @property
    def sticky(self) -> bool:
        return self.produced_tail or self.final_rem_sticky

    @property
    def round_increment(self) -> bool:
        return bool(self.guard and (self.round_bit or self.sticky or self.significand_lsb))


CONFIGS = [
    Config("w3_m5", Format(3, 5), 4096, "exact", 0x3005D1),
    Config("w4_m6", Format(4, 6), 4096, "exact", 0x4006D1),
    Config("w5_m11", Format(5, 11), 8192, "exact", 0x5011D1),
    Config("w6_m18", Format(6, 18), 8192, "exact", 0x6018D1),
    Config("w7_m17", Format(7, 17), 8192, "exact", 0x7017D1),
    Config("w8_m24", Format(8, 24), 20000, "numpy32", 0x8024D1),
    Config("w11_m53", Format(11, 53), 20000, "numpy64", 0x1153D1),
]


def qfrac(fmt: Format) -> int:
    qfrac_base = fmt.wman + 2
    return qfrac_base + (qfrac_base % 2)


def pack_bits(fmt: Format, sign: int, exp: int, frac: int) -> int:
    return (sign << fmt.sign_shift) | (exp << fmt.wfrac) | frac


def normal(fmt: Format, sign: int, exp: int, frac: int) -> int:
    assert 1 <= exp <= fmt.exp_max_finite
    assert 0 <= frac <= fmt.frac_mask
    return pack_bits(fmt, sign, exp, frac)


def canonical_inf(fmt: Format, sign: int) -> int:
    return pack_bits(fmt, sign, fmt.exp_inf, 0)


def zero(fmt: Format, sign: int = 0) -> int:
    return pack_bits(fmt, sign, 0, 0)


def sign_field(fmt: Format, bits: int) -> int:
    return (bits >> fmt.sign_shift) & 1


def exp_field(fmt: Format, bits: int) -> int:
    return (bits >> fmt.wfrac) & fmt.exp_inf


def frac_field(fmt: Format, bits: int) -> int:
    return bits & fmt.frac_mask


def is_zero(fmt: Format, bits: int) -> bool:
    return exp_field(fmt, bits) == 0


def is_inf(fmt: Format, bits: int) -> bool:
    return exp_field(fmt, bits) == fmt.exp_inf


def is_normal(fmt: Format, bits: int) -> bool:
    exp = exp_field(fmt, bits)
    return 0 < exp < fmt.exp_inf


def significand(fmt: Format, bits: int) -> int:
    return (1 << fmt.wfrac) | frac_field(fmt, bits)


def pow2_fraction(exp: int) -> Fraction:
    return Fraction(1 << exp, 1) if exp >= 0 else Fraction(1, 1 << -exp)


def floor_log2_fraction(value: Fraction) -> int:
    assert value > 0
    exp = value.numerator.bit_length() - value.denominator.bit_length()
    while pow2_fraction(exp + 1) <= value:
        exp += 1
    while pow2_fraction(exp) > value:
        exp -= 1
    return exp


def round_exact_normal(fmt: Format, sign: int, value: Fraction) -> int:
    exp_unbiased = floor_log2_fraction(value)
    scaled = value / pow2_fraction(exp_unbiased) * (1 << fmt.wfrac)
    quotient = scaled.numerator // scaled.denominator
    remainder = scaled.numerator % scaled.denominator

    increment = (2 * remainder) > scaled.denominator
    increment = increment or ((2 * remainder) == scaled.denominator and (quotient & 1) != 0)
    if increment:
        quotient += 1

    if quotient == (1 << fmt.wman):
        quotient >>= 1
        exp_unbiased += 1

    if exp_unbiased < fmt.min_exp_unbiased:
        return zero(fmt)
    if exp_unbiased > fmt.max_exp_unbiased:
        return canonical_inf(fmt, sign)

    exp = exp_unbiased + fmt.bias
    frac = quotient - (1 << fmt.wfrac)
    return normal(fmt, sign, exp, frac)


def exact_reference(fmt: Format, a: int, b: int) -> tuple[int, int]:
    a_zero = is_zero(fmt, a)
    b_zero = is_zero(fmt, b)
    a_inf = is_inf(fmt, a)
    b_inf = is_inf(fmt, b)
    div0 = 1 if b_zero else 0

    if a_zero or b_inf:
        return zero(fmt), div0

    result_sign = sign_field(fmt, a) if b_zero else sign_field(fmt, a) ^ sign_field(fmt, b)
    if b_zero or a_inf:
        return canonical_inf(fmt, result_sign), div0

    exp_delta = exp_field(fmt, a) - exp_field(fmt, b)
    value = Fraction(significand(fmt, a), significand(fmt, b)) * pow2_fraction(exp_delta)
    return round_exact_normal(fmt, result_sign, value), div0


def bits_to_numpy(bits: int, oracle: str) -> np.float32 | np.float64:
    if oracle == "numpy32":
        return np.array([bits], dtype=np.uint32).view(np.float32)[0]
    return np.array([bits], dtype=np.uint64).view(np.float64)[0]


def numpy_to_bits(value: np.float32 | np.float64, oracle: str) -> int:
    if oracle == "numpy32":
        return int(np.array([value], dtype=np.float32).view(np.uint32)[0])
    return int(np.array([value], dtype=np.float64).view(np.uint64)[0])


def canonicalize_numpy_result(fmt: Format, bits: int) -> int:
    sign = sign_field(fmt, bits)
    exp = exp_field(fmt, bits)
    frac = frac_field(fmt, bits)
    if exp == 0:
        return zero(fmt)
    if exp == fmt.exp_inf:
        return zero(fmt) if frac != 0 else canonical_inf(fmt, sign)
    return bits


def numpy_reference(fmt: Format, oracle: str, a: int, b: int) -> tuple[int, int]:
    a_zero = is_zero(fmt, a)
    b_zero = is_zero(fmt, b)
    a_inf = is_inf(fmt, a)
    b_inf = is_inf(fmt, b)
    div0 = 1 if b_zero else 0

    if a_zero or b_inf:
        return zero(fmt), div0

    result_sign = sign_field(fmt, a) if b_zero else sign_field(fmt, a) ^ sign_field(fmt, b)
    if b_zero or a_inf:
        return canonical_inf(fmt, result_sign), div0

    with np.errstate(all="ignore"):
        result = bits_to_numpy(a, oracle) / bits_to_numpy(b, oracle)
    return canonicalize_numpy_result(fmt, numpy_to_bits(result, oracle)), div0


def reference(config: Config, a: int, b: int) -> tuple[int, int]:
    if config.oracle == "exact":
        return exact_reference(config.fmt, a, b)
    return numpy_reference(config.fmt, config.oracle, a, b)


def observation(fmt: Format, a: int, b: int) -> Observation | None:
    if not is_normal(fmt, a) or not is_normal(fmt, b):
        return None

    qf = qfrac(fmt)
    raw = (significand(fmt, a) << qf) // significand(fmt, b)
    rem = (significand(fmt, a) << qf) % significand(fmt, b)
    high = ((raw >> qf) & 1) != 0

    if high:
        sig_shift = qf - fmt.wman + 1
        guard_shift = qf - fmt.wman
        round_shift = qf - fmt.wman - 1
        tail_width = qf - fmt.wman - 1
    else:
        sig_shift = qf - fmt.wman
        guard_shift = qf - fmt.wman - 1
        round_shift = qf - fmt.wman - 2
        tail_width = qf - fmt.wman - 2

    sig = (raw >> sig_shift) & ((1 << fmt.wman) - 1)
    tail_mask = (1 << tail_width) - 1 if tail_width > 0 else 0
    return Observation(
        high=high,
        significand_lsb=sig & 1,
        guard=(raw >> guard_shift) & 1,
        round_bit=(raw >> round_shift) & 1,
        produced_tail=(raw & tail_mask) != 0,
        final_rem_sticky=rem != 0,
    )


def vector_word(config: Config, a: int, b: int) -> int:
    fmt = config.fmt
    q, div0 = reference(config, a, b)
    return (a << (2 * fmt.wfull + 1)) | (b << (fmt.wfull + 1)) | (q << 1) | div0


def directed_basics(fmt: Format) -> list[tuple[str, int, int]]:
    one = normal(fmt, 0, fmt.bias, 0)
    minus_one = normal(fmt, 1, fmt.bias, 0)
    half = normal(fmt, 0, fmt.bias - 1, 0)
    one_and_half = normal(fmt, 0, fmt.bias, 1 << (fmt.wfrac - 1))
    one_and_quarter = normal(fmt, 0, fmt.bias, 1 << (fmt.wfrac - 2))
    one_and_three_quarters = normal(fmt, 0, fmt.bias, 3 << (fmt.wfrac - 2))
    two = normal(fmt, 0, fmt.bias + 1, 0)
    min_normal = normal(fmt, 0, 1, 0)
    neg_min_normal = normal(fmt, 1, 1, 0)
    max_finite = normal(fmt, 0, fmt.exp_max_finite, fmt.frac_mask)
    neg_max_finite = normal(fmt, 1, fmt.exp_max_finite, fmt.frac_mask)
    pos_inf = canonical_inf(fmt, 0)
    neg_inf = canonical_inf(fmt, 1)

    return [
        ("zero_div_one", zero(fmt), one),
        ("negative_zero_encoding_div_one", zero(fmt, 1), one),
        ("zero_div_zero", zero(fmt), zero(fmt)),
        ("one_div_zero", one, zero(fmt)),
        ("minus_one_div_zero", minus_one, zero(fmt)),
        ("one_div_one", one, one),
        ("minus_one_div_one", minus_one, one),
        ("one_div_minus_one", one, minus_one),
        ("minus_one_div_minus_one", minus_one, minus_one),
        ("one_and_half_div_two", one_and_half, two),
        ("one_and_quarter_div_one_and_half", one_and_quarter, one_and_half),
        ("one_and_half_div_one_and_half", one_and_half, one_and_half),
        ("one_div_pos_inf", one, pos_inf),
        ("minus_one_div_pos_inf", minus_one, pos_inf),
        ("two_div_neg_inf", two, neg_inf),
        ("pos_inf_div_one", pos_inf, one),
        ("neg_inf_div_one", neg_inf, one),
        ("pos_inf_div_pos_inf", pos_inf, pos_inf),
        ("min_normal_div_two_underflow", min_normal, two),
        ("neg_min_normal_div_two_underflow", neg_min_normal, two),
        ("min_normal_div_one", min_normal, one),
        ("neg_min_normal_div_one", neg_min_normal, one),
        ("max_finite_div_one", max_finite, one),
        ("neg_max_finite_div_one", neg_max_finite, one),
        ("max_finite_div_half_overflow", max_finite, half),
        ("neg_max_finite_div_half_overflow", neg_max_finite, half),
    ]


def normal_from_significands(fmt: Format, ma: int, mb: int) -> tuple[int, int]:
    a = normal(fmt, 0, fmt.bias, ma - (1 << fmt.wfrac))
    b = normal(fmt, 0, fmt.bias, mb - (1 << fmt.wfrac))
    return a, b


def find_rounding_case(
    fmt: Format,
    rng: np.random.Generator,
    predicate: object,
    max_random: int = 500_000,
) -> tuple[int, int] | None:
    lo = 1 << fmt.wfrac
    hi = 1 << fmt.wman

    if fmt.wman <= 11:
        for ma in range(lo, hi):
            for mb in range(lo, hi):
                a, b = normal_from_significands(fmt, ma, mb)
                obs = observation(fmt, a, b)
                if obs is not None and predicate(obs):
                    return a, b

    for _ in range(max_random):
        ma = int(rng.integers(lo, hi))
        mb = int(rng.integers(lo, hi))
        a, b = normal_from_significands(fmt, ma, mb)
        obs = observation(fmt, a, b)
        if obs is not None and predicate(obs):
            return a, b

    return None


def directed_rounding(config: Config, rng: np.random.Generator) -> list[tuple[str, int, int]]:
    predicates = [
        ("high_quotient_normalization", lambda obs: obs.high),
        ("low_quotient_normalization", lambda obs: not obs.high),
        ("guard_round_increment", lambda obs: obs.guard and obs.round_bit and obs.round_increment),
        (
            "sticky_from_produced_tail",
            lambda obs: obs.guard and not obs.round_bit and obs.produced_tail and obs.round_increment,
        ),
        (
            "sticky_from_final_remainder",
            lambda obs: obs.guard and not obs.round_bit and not obs.produced_tail and obs.final_rem_sticky,
        ),
    ]
    cases: list[tuple[str, int, int]] = []
    for label, predicate in predicates:
        case = find_rounding_case(config.fmt, rng, predicate)
        if case is None:
            raise RuntimeError(f"could not find {label} for WEXP={config.fmt.wexp} WMAN={config.fmt.wman}")
        cases.append((label, *case))
    return cases


def random_zero(fmt: Format) -> int:
    return zero(fmt)


def random_inf(fmt: Format, rng: np.random.Generator) -> int:
    return canonical_inf(fmt, int(rng.integers(0, 2)))


def random_normal(fmt: Format, rng: np.random.Generator) -> int:
    return normal(
        fmt,
        int(rng.integers(0, 2)),
        int(rng.integers(1, fmt.exp_max_finite + 1)),
        int(rng.integers(0, fmt.frac_mask + 1)),
    )


def random_normal_near(
    fmt: Format,
    rng: np.random.Generator,
    exponents: list[int],
    fractions: list[int],
) -> int:
    exp = int(np.clip(int(rng.choice(exponents)) + int(rng.integers(-1, 2)), 1, fmt.exp_max_finite))
    frac = int(np.clip(int(rng.choice(fractions)) + int(rng.integers(-16, 17)), 0, fmt.frac_mask))
    return normal(fmt, int(rng.integers(0, 2)), exp, frac)


def random_operand(fmt: Format, rng: np.random.Generator) -> int:
    mode = int(rng.integers(0, 12))
    if mode == 0:
        return random_zero(fmt)
    if mode == 1:
        return random_inf(fmt, rng)
    if mode == 2:
        return random_normal_near(fmt, rng, [1, 2, 3], [0, 1, fmt.frac_mask])
    if mode == 3:
        return random_normal_near(fmt, rng, [fmt.bias - 1, fmt.bias, fmt.bias + 1], [0, 1])
    if mode == 4:
        return random_normal_near(
            fmt,
            rng,
            [fmt.exp_max_finite - 2, fmt.exp_max_finite - 1, fmt.exp_max_finite],
            [0, 1 << (fmt.wfrac - 1), fmt.frac_mask],
        )
    return random_normal(fmt, rng)


def random_case(config: Config, rng: np.random.Generator) -> tuple[int, int]:
    fmt = config.fmt
    one = normal(fmt, 0, fmt.bias, 0)
    two = normal(fmt, 0, fmt.bias + 1, 0)
    half = normal(fmt, 0, fmt.bias - 1, 0)
    mode = int(rng.integers(0, 13))
    if mode == 0:
        return random_zero(fmt), random_operand(fmt, rng)
    if mode == 1:
        return random_operand(fmt, rng), random_zero(fmt)
    if mode == 2:
        return random_normal(fmt, rng), random_inf(fmt, rng)
    if mode == 3:
        return random_inf(fmt, rng), random_normal(fmt, rng)
    if mode == 4:
        return random_normal_near(fmt, rng, [1, 2], [0, 1]), random_normal_near(fmt, rng, [fmt.bias], [0])
    if mode == 5:
        return random_normal_near(fmt, rng, [fmt.exp_max_finite], [fmt.frac_mask]), half
    if mode == 6:
        return random_normal_near(fmt, rng, [fmt.bias], [0, 1]), random_normal_near(
            fmt,
            rng,
            [fmt.bias],
            [0, 1, 1 << (fmt.wfrac - 1)],
        )
    if mode == 7:
        return normal(fmt, int(rng.integers(0, 2)), 1, int(rng.integers(0, 4))), two
    if mode == 8:
        return normal(fmt, int(rng.integers(0, 2)), fmt.exp_max_finite, fmt.frac_mask), half
    if mode == 9:
        return random_normal(fmt, rng), one
    return random_operand(fmt, rng), random_operand(fmt, rng)


def add_case(
    config: Config,
    cases: list[tuple[str, int, int]],
    seen: set[tuple[int, int]],
    label: str,
    a: int,
    b: int,
) -> None:
    key = (a, b)
    if key in seen:
        return
    reference(config, a, b)
    seen.add(key)
    cases.append((label, a, b))


def generate_cases(config: Config) -> list[tuple[str, int, int]]:
    rng = np.random.default_rng(config.seed)
    cases: list[tuple[str, int, int]] = []
    seen: set[tuple[int, int]] = set()

    for label, a, b in directed_basics(config.fmt):
        add_case(config, cases, seen, label, a, b)

    for label, a, b in directed_rounding(config, rng):
        add_case(config, cases, seen, label, a, b)

    while len(cases) < config.count:
        a, b = random_case(config, rng)
        add_case(config, cases, seen, "random", a, b)

    return cases


def render_vectors(config: Config) -> str:
    hex_width = ((3 * config.fmt.wfull) + 4) // 4
    lines = []
    for index, (label, a, b) in enumerate(generate_cases(config)):
        suffix = f" // {index:05d} {label}" if label != "random" else ""
        lines.append(f"{vector_word(config, a, b):0{hex_width}x}{suffix}")
    return "\n".join(lines) + "\n"


def output_path(output_dir: Path, config: Config) -> Path:
    return output_dir / f"div_ext_{config.name}.memh"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    failed = False
    for config in CONFIGS:
        text = render_vectors(config)
        path = output_path(args.output_dir, config)
        if args.check:
            if not path.exists() or path.read_text() != text:
                print(f"{path} is stale", file=sys.stderr)
                failed = True
            else:
                print(f"{path} is up to date")
        else:
            path.write_text(text)
            print(f"wrote {config.count} vectors to {path}")

    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
