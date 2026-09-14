# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users

Mac players are the primary users. They need reliable controllers in games, emulators, SDL apps,
and native macOS apps.

Power users and contributors also use profiles, diagnostics, packet tools, compatibility identities,
and the CLI.

## Product Purpose

OpenJoystickDriver is a macOS userspace gamepad driver. It reads physical controllers, normalizes
input, applies profiles, controls physical effects, and publishes compatible virtual controllers.

Success means reliable input without duplicate devices, stuck controls, hidden failures, or false
runtime state.

## Positioning

One signed app owns the path from physical transport to application compatibility. Automatic mode
keeps native HID visibility. Explicit identities provide a virtual controller when an app needs a
different contract.

## Operating Context

- The menu bar shows readiness, controllers, profiles, and common actions.
- The workbench provides setup, Input Test, profiles, compatibility controls, logs, and diagnostics.
- The authenticated CLI provides automation, controller tools, profile operations, and support
  reports.
- A suspended OpenJoystickDriver session does not terminate the physical USB or Bluetooth link.

## Capabilities and Constraints

- The native Swift app supports macOS 10.15 and later. The app binary hosts the runtime and CLI.
- HID input requires Input Monitoring. Virtual HID output requires Accessibility.
- Automatic mode does not duplicate native HID controllers. Each physical runtime identifier owns
  no more than one virtual output.
- Explicit identities include Generic HID, SDL 2/3, Apple GameController, Xbox 360 HID, DualShock 4,
  DualSense, and Switch Pro.
- Compatibility changes use bounded work. Status reports the requested, live, and retained identity
  with typed failure details.
- Profile operations affect only their controller. They do not report false physical disconnects.
- Suspend neutralizes input and effects, removes virtual output, and ignores input until Resume or
  physical reconnect.
- DualShock 4 Bluetooth input requires valid framing and CRC. Stale non-neutral input retires after
  one second and recovers after a neutral report.
- GameSir G7 SE startup requires the GIP LED command after USB open, recovery, and Resume.
- Existing profile schemas and legacy RPC payloads remain compatible.
- Repository generators own controller catalogs and DriverKit files.

## Brand Commitments

- The product name is **OpenJoystickDriver**.
- Product language is direct and factual. It keeps physical connection, session state, identity,
  and failure state separate.
- The project uses the MIT License.
- Xbox and PlayStation names identify compatibility only. The project is not affiliated with
  Microsoft or Sony.
- The interface remains a native macOS utility, not a game-console or web-dashboard imitation.

## Evidence on Hand

- `README.md` defines the product promise, setup, permissions, and compatibility targets.
- `docs/user/compatibility.md` defines supported hardware and apps.
- `docs/development/cli-and-runtime.md` defines runtime, CLI, session, and compatibility contracts.
- `DESIGN.md` defines interface roles, responsive behavior, state language, and accessibility.
- Tests under `Tests/` verify product behavior. Local hardware tests cover GameSir G7 SE and a
  wireless DualShock 4 in PCSX2 2.8.2.
- The repository has no approved testimonials, customer logos, adoption metrics, pricing claims, or
  press quotations. Do not invent them.

## Product Principles

1. **Prefer native input.** Do not publish a virtual controller when macOS exposes the physical
   controller correctly.
2. **Show live state.** Show the active, retained, suspended, or failed state.
3. **Fail neutral.** Bound transport work, release input, retire failed output, and recover locally.
4. **Isolate controllers.** Change only the controller that owns an operation.
5. **Keep common tasks simple.** Keep detailed evidence available in diagnostics and the CLI.

## Accessibility & Inclusion

- Status uses text or a supported SF Symbol. Color is not the only status signal.
- The app supports keyboard navigation, focus rings, system contrast, reduced motion, and VoiceOver.
- The app names unknown, inactive, suspended, and failed states with explicit localized text.
- The canonical localization source supplies 83 locale catalogs.
