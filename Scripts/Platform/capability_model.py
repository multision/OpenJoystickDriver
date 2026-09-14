"""Capability domain model."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum
from pathlib import Path


class Capability(Enum):
    SCHEMA_PYTHON = "schema Python environment"
    SWIFT_TOOLCHAIN = "Swift toolchain"
    FULL_XCODE = "full Xcode"
    SWIFTLINT = "SwiftLint"
    SHELLCHECK = "ShellCheck"
    LEFTHOOK = "Lefthook"
    JUST = "Just"
    PKG_CONFIG = "pkg-config"
    SDL3 = "SDL3"
    GH = "GitHub CLI"
    GH_AUTH = "GitHub authentication"
    DEVELOPMENT_SIGNING = "development signing"
    RELEASE_SIGNING = "release signing"
    NOTARIZATION = "notarization credentials"
    RUFF = "Ruff"
    PYRIGHT = "Pyright"
    XMAKE = "Xmake"


class OutcomeKind(Enum):
    AVAILABLE = "available"
    REPAIRED = "repaired"
    EXTERNALLY_BLOCKED = "externally blocked"
    DECLINED = "declined"
    UNSUPPORTED = "unsupported"


@dataclass(frozen=True)
class RepairOutcome:
    capability: Capability
    kind: OutcomeKind
    detail: str = ""


class CapabilityError(RuntimeError):
    def __init__(self, outcome: RepairOutcome):
        self.outcome = outcome
        super().__init__(
            outcome.detail or f"{outcome.capability.value}: {outcome.kind.value}"
        )


FORMULAS: dict[Capability, tuple[str, str]] = {
    Capability.SWIFTLINT: ("swiftlint", "swiftlint"),
    Capability.SHELLCHECK: ("shellcheck", "shellcheck"),
    Capability.LEFTHOOK: ("lefthook", "lefthook"),
    Capability.JUST: ("just", "just"),
    Capability.PKG_CONFIG: ("pkg-config", "pkg-config"),
    Capability.SDL3: ("sdl3", "sdl3"),
    Capability.GH: ("gh", "gh"),
    Capability.RUFF: ("ruff", "ruff"),
    Capability.PYRIGHT: ("pyright", "pyright"),
    Capability.XMAKE: ("xmake", "xmake"),
}


def _truthy(value: str | None) -> bool:
    return value is not None and value.lower() not in {"", "0", "false", "no"}


def _load_env_file(
    path: Path, environ: Mapping[str, str] | None = None
) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        if environ is not None:
            home = environ.get("HOME", "")
            value = value.replace("${HOME}", home).replace("$HOME", home)
        values[key.strip()] = os.path.expanduser(value)
    return values


def update_env_value(path: Path, key: str, value: str) -> None:
    """Atomically update one shell environment assignment without touching other keys."""
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    assignment = f'{key}="{value}"'
    replaced = False
    result: list[str] = []
    for line in lines:
        if line.startswith(f"{key}="):
            if not replaced:
                result.append(assignment)
                replaced = True
        else:
            result.append(line)
    if not replaced:
        if result and result[-1]:
            result.append("")
        result.append(assignment)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text("\n".join(result) + "\n", encoding="utf-8")
    os.replace(temporary, path)
