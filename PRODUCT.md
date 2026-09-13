# OpenJoystickDriver Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS 10.15 and later, using AppKit and SwiftUI.

## Users

Controller owners are the primary users. They use OpenJoystickDriver to connect, inspect, test,
configure, and remap physical game controllers on a Mac. Power users need direct access to runtime
state and output controls; developer diagnostics remain explicitly opt-in.

## Product Purpose

OpenJoystickDriver is a userspace macOS gamepad driver and controller workbench. Success means a
connected controller is represented truthfully, permissions and runtime readiness are obvious, and
testing or configuration can be completed without leaving the app.

## Positioning

The product joins driver runtime ownership, controller-aware input and output testing, remapping,
and support diagnostics in one native macOS workflow. Protocol-derived values must preserve the
precision actually supplied by the hardware.

## Operating Context

The app lives in the menu bar and opens a Controller Workbench for Overview, Controllers, Profiles,
Console, optional Developer Tools, and Settings. Input Test is a separate saved window used while a
physical controller is active. Workflows must tolerate reconnects, permission changes, unavailable
services, empty device lists, and long localized text.

## Capabilities and Constraints

- Preserve existing controller discovery, profile editing, input sampling, physical rumble,
  lighting ownership, diagnostics, localization, and accessibility behavior.
- DS4 hardware reports coarse battery buckets and state flags, not continuous charging progress.
- Use native macOS controls, semantic colors, and window behavior. Do not add unrelated controller
  diagnostics.
- Preserve macOS 10.15 support and saved window geometry.
- ControllerTest.io is a structural reference for a compact test dashboard only; its styling and
  feature set are not product assets.

## Brand Commitments

The product name is OpenJoystickDriver. The interface is a precise native utility: direct labels,
compact data presentation, restrained system materials, and controller-family accents used only for
identity or live state.

## Evidence on Hand

Source, tests, schemas, and recorded hardware observations in this repository are authoritative.
No commercial claims, performance scores, or unrecorded hardware capabilities may be fabricated.

## Product Principles

1. Report only what the controller and runtime actually know.
2. Put readiness and the current controller state before configuration detail.
3. Keep common controller workflows prominent and developer-only controls opt-in.
4. Adapt structure to available window width instead of forcing window growth.
5. Preserve native keyboard, accessibility, localization, and window conventions.

## Accessibility & Inclusion

All destinations and controls require keyboard navigation and useful VoiceOver labels. Layouts must
remain reachable at minimum window sizes, in light and dark appearances, and with long localized
copy.
