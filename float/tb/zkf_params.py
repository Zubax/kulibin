#!/usr/bin/env python3
"""Cocotb plusarg parsing and configuration checks for ZKF tests."""

from __future__ import annotations

from dataclasses import dataclass
import os
from typing import Iterable

import cocotb


VALID_KINDS = {"directed", "exhaustive", "random"}


@dataclass(frozen=True)
class TestContext:
    suite: str
    config: str
    seed: int
    kind: str = "directed"
    count: int = 0
    wexp: int | None = None
    wman: int | None = None
    wexp_unbiased: int | None = None
    pipe_w: int | None = None
    pipe_n: int | None = None

    @property
    def params(self) -> str:
        if self.wexp is not None and self.wman is not None:
            return f"{self.config} WEXP={self.wexp} WMAN={self.wman}"
        if self.pipe_w is not None and self.pipe_n is not None:
            return f"{self.config} W={self.pipe_w} N={self.pipe_n}"
        return self.config

    def prefix(self) -> str:
        return (
            f"suite={self.suite} params={self.params} kind={self.kind} "
            f"count={self.count} seed=0x{self.seed:016x}"
        )


def _runtime_plusargs() -> dict[str, object]:
    return getattr(cocotb, "plusargs", {})


def _get_text(name: str, default: str | None = None, aliases: Iterable[str] = ()) -> str | None:
    for candidate in (name, *aliases):
        value = _runtime_plusargs().get(candidate)
        if value is not None and value is not True:
            return str(value)
        if candidate in os.environ:
            return os.environ[candidate]
    return default


def plusarg_str(name: str, default: str | None = None, aliases: Iterable[str] = ()) -> str:
    value = _get_text(name, default, aliases)
    if value is None:
        raise ValueError(f"required plusarg +{name}=... is missing")
    return value


def plusarg_int(name: str, default: int | None = None, aliases: Iterable[str] = ()) -> int:
    text = _get_text(name, None, aliases)
    if text is None:
        if default is None:
            raise ValueError(f"required plusarg +{name}=... is missing")
        return default
    return int(text, 0)


def _seed() -> int:
    seed = plusarg_int("ZKF_SEED", 0)
    if seed < 0:
        raise ValueError(f"ZKF_SEED must be non-negative, got {seed}")
    return seed


def _kind() -> str:
    kind = plusarg_str("ZKF_KIND", "directed")
    if kind not in VALID_KINDS:
        raise ValueError(f"ZKF_KIND must be one of {sorted(VALID_KINDS)}, got {kind!r}")
    return kind


def float_context(suite: str, require_wexp_unbiased: bool = False) -> TestContext:
    wexp = plusarg_int("ZKF_WEXP")
    wman = plusarg_int("ZKF_WMAN")
    wexp_unbiased = plusarg_int("ZKF_WEXP_UNBIASED", wexp + 2) if require_wexp_unbiased else None
    if wexp < 2:
        raise ValueError(f"ZKF_WEXP must be at least 2, got {wexp}")
    if wman < 4:
        raise ValueError(f"ZKF_WMAN must be at least 4, got {wman}")
    if wexp_unbiased is not None and wexp_unbiased < wexp + 1:
        raise ValueError(
            f"ZKF_WEXP_UNBIASED={wexp_unbiased} is too narrow for ZKF_WEXP={wexp}"
        )
    return TestContext(
        suite=suite,
        config=plusarg_str("ZKF_CONFIG", "default"),
        seed=_seed(),
        kind=_kind(),
        count=plusarg_int("ZKF_COUNT", 0, aliases=("ZKF_RANDOM_COUNT",)),
        wexp=wexp,
        wman=wman,
        wexp_unbiased=wexp_unbiased,
    )


def pipe_context() -> TestContext:
    width = plusarg_int("ZKF_PIPE_W")
    stages = plusarg_int("ZKF_PIPE_N")
    if width < 1:
        raise ValueError(f"ZKF_PIPE_W must be positive, got {width}")
    if stages < 0:
        raise ValueError(f"ZKF_PIPE_N must be non-negative, got {stages}")
    return TestContext(
        suite="pipe",
        config=plusarg_str("ZKF_CONFIG", "default"),
        seed=_seed(),
        kind="random",
        count=plusarg_int("ZKF_COUNT", 64, aliases=("ZKF_PIPE_COUNT",)),
        pipe_w=width,
        pipe_n=stages,
    )


def signal_width(handle) -> int:
    try:
        return len(handle)
    except TypeError:
        return 1


def check_width(label: str, handle, expected: int, context: TestContext) -> None:
    observed = signal_width(handle)
    if observed != expected:
        raise AssertionError(
            f"{context.prefix()} {label} width mismatch expected={expected} observed={observed}"
        )
