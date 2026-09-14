---
name: add-controller-openjoystickdriver
description: >-
  Add or import OpenJoystickDriver controller catalog data from pinned sources
  or recorded evidence, then regenerate and validate it. Not for live hardware
  diagnosis or hand-editing generated records.
---

# Add Controller Support

Add one controller identity or factual device deviation through the canonical catalog inputs.

## Procedure

1. Read `AGENTS.md`, `Resources/Schemas/AGENTS.md`, `docs/development/xpad-import.md`, and `docs/testing/controller-record.md`.
2. Load [controller data ownership](references/controller-data.md) to choose a pinned-source import, local `add`, or evidence-backed `patch`.
3. Record the exact decimal VID/PID, connection mode, protocol, evidence source, and unknowns in the relevant testing page.
4. Edit `Resources/ControllerSources.lock.json`, `Resources/ControllerOverrides/`, a schema, or generator source. Never edit generated controller records.
5. After reviewing the authored change, regenerate once:

   ```bash
   ./Scripts/ojd catalog regenerate --write
   ```

6. Inspect the generated diff for the intended record and unrelated churn.
7. Run:

   ```bash
   ./Scripts/ojd catalog regenerate --check
   ./Scripts/ojd check profiles
   ./Scripts/ojd check schemas
   swift test
   git diff --check
   ```

## Rules

- Use the unversioned lowerCamelCase schema and decimal JSON numbers.
- An `add` must not collide with upstream data. A `patch` must target an upstream record and change only necessary top-level sections.
- Keep shared parsing behavior in Swift. Records hold operational facts, not provenance, confidence flags, or duplicate parser logic.
- Source recognition and passing generators do not prove physical hardware behavior.
- Route packet capture or physical output work to `$debug-controller-openjoystickdriver` and behavioral test design to `$test-openjoystickdriver`.

## Completion

Report authored inputs, generated outputs, checks, and whether each claim is source-backed, packet-backed, or hardware-verified. Name unresolved hardware, signing, permission, and platform gaps.
