---
name: test-openjoystickdriver
description: >-
  Prove OpenJoystickDriver Swift product behavior with focused tests and
  repository gates. Not for script/prose fixtures, catalog authoring, or live
  hardware diagnosis.
---

# Test Product Behavior

Create executable evidence for one observable Swift product contract.

## Procedure

1. Read `AGENTS.md`, `Package.swift`, `CONTRIBUTING.md`, the source owner, and its nearest test owner.
2. Define the input, expected typed result or state transition, and a plausible incorrect implementation.
3. Add the smallest test that passes only for the intended behavior. Exercise public APIs or use `@testable import`.
4. Assert routes, codes, identifiers, typed payloads, events, return values, state transitions, and invariants—not help text or implementation wording.
5. Load [validation](references/validation.md), run the focused test first, then applicable gates in order.
6. Repair failures at their cause. Use `./Scripts/ojd repair swiftpm-module-cache` only for the documented cache mismatch, then rerun the failed command.

## Prohibited Tests

- Do not create `Tests/Scripts` or test shell/Python implementation from Swift.
- Do not read Swift source, scripts, documentation, or generated output and assert substrings or regex matches.
- Do not assert human-readable help, diagnostics, or formatting.
- Do not use a parser fixture, schema check, or source review as proof of physical hardware behavior.

Route catalog work to `$add-controller-openjoystickdriver`, hardware diagnosis to `$debug-controller-openjoystickdriver`, and ownership moves to `$organize-openjoystickdriver`.

## Completion

Report the observable contract, focused and broad commands with results, skipped hardware/signing/platform checks, and remaining risk. Never report an unrun gate as passing.
