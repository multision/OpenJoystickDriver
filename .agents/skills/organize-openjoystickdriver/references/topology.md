# Source And Test Ownership

Load this map before moving code. Verify exact paths in the worktree and use `docs/development/source-topology.md` for the current decision.

## Targets

| Target | Owner |
| --- | --- |
| `OpenJoystickDriverKit` | Reusable controller/domain behavior and service contracts |
| `OpenJoystickDriverRelay` | SwifterKit DriverKit adapter |
| `DriverKitGenerator` | Native-project generator input |
| `OpenJoystickDriver` | App composition, UI, CLI, and runtime adapters |
| `OpenJoystickDriverHIDTool` | Focused hardware investigation |
| `OpenJoystickDriverGameControllerProbe` | Isolated visibility probe |

Dependency direction is `App → Kit`, `App → Relay → Kit`, `Generator → Relay`, and `HIDTool → Kit`. Kit never imports SwifterKit.

## Matching Tests

Kit capability directories map to the same directory under `Tests/OpenJoystickDriverKitTests/`: `ApplicationService`, `Device`, `Diagnostics`, `Output`, `Permissions`, `Process`, `Protocol`, `Remapping`, and `Update`. `HID` uses the nearest HID, Device, or Integration owner.

App capability directories map under `Tests/OpenJoystickDriverTests/`: `App/Presentation`, `CLI`, `Remapping`, `Runtime`, and `Status`. Controllers, MenuBar, and Diagnostics use the nearest presentation or runtime owner.

Nested directories deepen a behavior owner. `Integration/` is test-only for cross-capability contracts.

## Move Record

For every moved declaration, record its behavior owner, target, visibility, lifecycle, dependencies, matching test, generated-input owner, and rollback path. If these disagree, stop and document the architecture decision instead of adding a generic bucket or alias.
