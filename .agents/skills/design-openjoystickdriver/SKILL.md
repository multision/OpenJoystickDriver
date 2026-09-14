---
name: design-openjoystickdriver
description: >-
  Design or change OpenJoystickDriver's macOS menu-bar, settings, SwiftUI, or
  AppKit experience, including accessibility and runtime states. Not for
  protocol-only behavior or generated output.
---

# Design OpenJoystickDriver UI

Deliver one native, accessible user flow while keeping controller and protocol behavior outside presentation code.

## Procedure

1. Read `DESIGN.md`, `LOCALIZATION.md`, and the affected source and tests.
2. Load [Apple platform seams](references/apple-platform.md) when the change touches window ownership, menu behavior, permissions, loading, errors, or accessibility.
3. Define the primary action, prerequisite, success state, and recovery path.
4. Reuse semantic macOS controls, materials, symbols, colors, and existing view models. Keep application, window, and observable UI state on `@MainActor`.
5. Represent loading, empty, unavailable, permission-denied, stale, and error states explicitly when applicable.
6. Keep all controls keyboard reachable and give non-text controls useful VoiceOver labels.
7. Use localization keys and verify long copy, minimum window size, light/dark appearance, reduced motion, and reconnect behavior.
8. Run focused Swift tests, formatting/lint, `swift test`, and `git diff --check`.

## Boundaries

- Do not duplicate domain validation or transport state in a view.
- Do not claim hardware behavior from previews or source inspection.
- Preserve macOS 10.15 behavior and saved window geometry.
- Route domain implementation to `$maintain-openjoystickdriver` and behavioral test design to `$test-openjoystickdriver`.

## Completion

Report the user path, state coverage, accessibility checks, localization impact, executed commands, and any unverified platform or hardware behavior.
