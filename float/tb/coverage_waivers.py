#!/usr/bin/env python3
"""Declarative coverage waivers for the Verilator-driven RTL coverage gate.

Each waiver names a specific RTL site whose line/branch coverage is
intentionally not enforced, paired with a short proof. The aggregator
subtracts the waived lines before computing the missing-coverage count.

The supported kinds are:

- ``elaboration``: code reachable only via an elaboration-time error stub
  (e.g. ``_zkf_invalid_wexp_or_wman``).
- ``parametric``: code whose presence depends on module parameters; both
  paths are exercised across the configuration sweep but Verilator reports
  per-build, so individual builds appear uncovered for the path their
  parameters do not generate.
- ``structural``: combinational invariant that prevents a branch from
  being taken (e.g. mutually-exclusive force-zero/force-inf precedence).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Waiver:
    file_basename: str
    line_range: tuple[int, int]
    kind: str
    reason: str

    def lines(self) -> range:
        return range(self.line_range[0], self.line_range[1] + 1)


WAIVERS: list[Waiver] = [
    Waiver(
        file_basename="zkf_add.v",
        line_range=(22, 24),
        kind="elaboration",
        reason="g_invalid_wman: elaboration-time error stub; unreachable for valid WEXP>=2, WMAN>=4",
    ),
    Waiver(
        file_basename="_zkf_pack.v",
        line_range=(36, 38),
        kind="elaboration",
        reason="g_invalid_wman: elaboration-time error stub; unreachable for valid params",
    ),
    Waiver(
        file_basename="zkf_mul.v",
        line_range=(22, 24),
        kind="elaboration",
        reason="g_invalid_wman: elaboration-time error stub; unreachable for valid params",
    ),
    Waiver(
        file_basename="_zkf_div_core.v",
        line_range=(38, 40),
        kind="elaboration",
        reason="g_invalid_wman: elaboration-time error stub; unreachable for valid params",
    ),
    Waiver(
        file_basename="_zkf_div_core.v",
        line_range=(191, 195),
        kind="structural",
        reason="g_no_final_tail_hi is unreachable for any valid WMAN >= 4 (QFRAC >= WMAN+2 ⇒ TAIL_HI_WIDTH >= 1); see the inline RTL comment. Kept for generate-completeness.",
    ),
    Waiver(
        file_basename="_zkf_pack.v",
        line_range=(88, 88),
        kind="structural",
        reason="s1_zero_y is a continuous-assign of the all-zeros constant; Verilator marks the line as uncovered since no runtime expression evaluates here",
    ),
    Waiver(
        file_basename="_zkf_pack.v",
        line_range=(127, 128),
        kind="structural",
        reason="_zkf_pack_delay reset branch unreachable in this suite: the sole instantiation in zkf_div.v ties rst to 1'b0 because the delayed payload (div0) carries no control state",
    ),
]


def waived_lines_for(file_basename: str) -> set[int]:
    """Return the set of waived 1-based line numbers for a given source file."""
    return {line for w in WAIVERS for line in w.lines() if w.file_basename == file_basename}


def waivers_for(file_basename: str) -> list[Waiver]:
    return [w for w in WAIVERS if w.file_basename == file_basename]
