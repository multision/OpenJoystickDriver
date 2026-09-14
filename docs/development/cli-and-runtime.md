# CLI And Application Runtime

The signed application bundle provides the menu-bar and settings interface for the
in-process controller runtime. With `--headless`, the same executable provides the
expert CLI for automation, advanced mappings, and diagnostics. The app host does
not shell out to the CLI. See [Architecture](architecture.md) for the shared
contracts, local-RPC boundary, and process lifecycle.

| Capability | Shared owner |
| --- | --- |
| Controller listing and input state | `DeviceManager` and application-service payloads |
| Permission status and requests | `PermissionManager` in the running host |
| Virtual-device mode and diagnostics | `ApplicationServiceServer` |
| Physical output and remapping | Typed application-service payloads and remapping router |
| Runtime health | `ApplicationServiceManager` and the RPC socket PID |
| Logs | `ApplicationServiceLogService` |
| Updates and reports | CLI commands and shared report/update services |

## Application Host

Launching `OpenJoystickDriver.app` starts `ApplicationServiceRuntime` once, then
installs the AppKit status-item menu and reusable settings window facade. See
[Architecture](architecture.md) for host identity, socket ownership, and login
registration.

## CLI

The installed `/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless` CLI remains the supported expert
interface for automation, complete mapping operations, streaming input, and
diagnostics. The menu-bar/settings facade is the supported consumer interface for
readiness, permissions, connected controllers, profiles, and ordinary remapping.
With CLI arguments, `swift run OpenJoystickDriver` or
`.build/debug/OpenJoystickDriver` uses the installed signed executable when available. The
server still checks the user, signing identifier, and team identifier. If the
repository sources are newer than the installed executable, the command stops
and asks for a new install instead of running stale code.

Run `./Scripts/ojd build install-fast dev` after source changes. Set
`OJD_RUN_REPOSITORY_CLI=1` only to run a local command that does not use the
application service. An unsigned repository executable cannot connect to the
running service.
Repository development, build, validation, and release tasks use the separate
maintainer command, `./Scripts/ojd`. Direct use of `OpenJoystickDriverHIDTool` is
internal and supported only for focused hardware investigation.

CLI command families:

```text
status [--json]
controller list|state|packets|watch|output ...
map ...
app status|login enable|disable|logs ...
extension status|enable|disable
permissions ...
compat show|set <identity>|reset
test [positive-seconds]
diagnose [runtime|catalog|report]
update check ...
```

## Workflow Capability Matrix

| Runtime CLI workflow | GUI destination or classification |
| --- | --- |
| `status` and `diagnose runtime` | Overview and Developer Tools runtime health |
| `controller list` | Controllers |
| `controller state` and `controller watch` | Controllers → Input Test |
| `controller output` | Controllers → Input Test output controls |
| `controller packets` | Developer Tools packet capture |
| `map` profile authoring and activation | Profiles |
| `permissions` | Overview access cards |
| `compat show/set/reset` | Controllers → Controller identity |
| `app logs` and `diagnose report` | Console and Developer Tools report actions |
| `extension status/enable/disable` | Overview driver setup, repair, and uninstall |
| `update check` | Settings → Updates |
| JSON/JSONL output, scripting, soak tests, catalog diagnostics, packaging, catalog generation, and DriverKit generation | Automation-only |

`--timeout <seconds>` applies to bounded application-service calls. Controller
operations retain opaque `--device` selection and ambiguity rejection.
Machine-readable output uses `--json` where supported. Stream commands use
their documented JSONL mode.

Keep raw packets, runtime soaking, catalog inspection, permission audits, and
virtual-device self-tests in the CLI: their output is diagnostic, verbose, or
unsuitable for an always-present consumer interface.

## Controller Sessions and Compatibility

`controller disconnect` suspends a controller from OpenJoystickDriver without terminating its
physical Bluetooth or USB link. Suspension neutralizes input and physical effects, removes OJD
virtual output, and keeps the controller visible. `controller resume` repeats required startup
output and re-enables input; a physical reconnect creates a new active session.

The additive detailed compatibility RPC reports the requested, live, and retained identities plus
a typed failure phase and cause. The legacy Boolean RPC remains available. Automatic mode passes
HID controllers through to macOS without publishing an OJD virtual gamepad. Selecting an explicit
identity intentionally overrides pass-through.
