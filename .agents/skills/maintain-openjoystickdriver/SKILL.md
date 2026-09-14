---
name: maintain-openjoystickdriver
description: >-
  Implement or repair OpenJoystickDriver Swift product behavior within an
  existing package owner. Not for catalog authoring, physical diagnosis,
  topology-only moves, or generated output.
---

# Maintain Product Behavior

Implement one coherent behavior change at its existing owner with one clear runtime path.

## Procedure

1. Read `AGENTS.md`, `Package.swift`, `CONTRIBUTING.md`, and the nearest source and tests.
2. Load [product boundaries](references/boundaries.md) before changing imports, generated inputs, transport, application service, or DriverKit generation.
3. Define the observable input, output, state transition, and failure owner.
4. Use CodeGraph before text search when `.codegraph/` exists. Trace callers and matching tests.
5. Make the smallest complete change. Keep protocol/domain behavior in Kit, app composition in the app, and platform USB access in `OpenJoystickDriverUSB`.
6. Update canonical inputs and regenerate; never patch generated controller or DriverKit output.
7. Add only a behavioral test that fails for the incorrect implementation.
8. Run the focused test, applicable repository checks, `swift test`, and `git diff --check`.

## Rules

- Preserve typed errors and absence; do not add swallowed errors, unsafe type erasure, duplicate validation, or compatibility shims.
- Keep the Swift 6 concurrency boundary: device session mutation stays off `@MainActor`; presentation stays on it.
- Do not broaden signing, permissions, entitlements, or hardware claims without focused evidence.
- Route catalog inputs to `$add-controller-openjoystickdriver`, hardware observations to `$debug-controller-openjoystickdriver`, and ownership moves to `$organize-openjoystickdriver`.

## Completion

Report behavior changed, owning paths, tests and checks run, generated inputs/outputs, and remaining hardware, signing, permission, or platform risk.
