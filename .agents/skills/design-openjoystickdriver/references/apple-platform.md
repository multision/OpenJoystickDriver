# Apple Platform Seams

Load this reference for window ownership, menu behavior, permissions, loading, error states, or accessibility.

## Ownership

Presentation lives in `Sources/OpenJoystickDriver/App/Presentation/`. Its owners are `Controllers`, `InputCapture`, `Profiles`, `Runtime`, `Settings`, and `MenuBar`. Matching tests live under `Tests/OpenJoystickDriverTests/App/Presentation/`; Controllers, MenuBar, and Diagnostics use their nearest flow or runtime owner.

Keep controller and protocol behavior in `Sources/OpenJoystickDriverKit/`. The app owns one `ApplicationServiceRuntime` gateway.

```mermaid
flowchart LR
  Menu[Menu bar] --> Window[Reusable settings window]
  Window --> State[Presentation state]
  State --> Gateway[Typed runtime gateway]
  Gateway --> Runtime[ApplicationServiceRuntime]
```

## Required States

Define applicable behavior for loading and cancellation, empty or unavailable data, denied permission, unavailable system extension, IPC failure, stale responses, recovery, and success. Never rely on animation or prose alone.

## Proof Points

- One reusable settings window and runtime instance.
- Semantic native controls, visible labels, logical focus order, keyboard access, and VoiceOver names.
- Usable system text sizing, contrast, light/dark appearance, minimum window size, long localization, and reduced motion.
- Permission copy that links to system settings without claiming unobserved access.
- Behavioral tests for gateway and state changes. Use visual inspection for layout; never assert view prose from source text.
