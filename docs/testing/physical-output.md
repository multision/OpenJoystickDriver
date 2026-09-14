# Test Physical Output

OpenJoystickDriver generates manual test instructions from a connected controller's reported output capabilities, not proof of a hardware pass.

## Generate A Plan

List connected devices. Then request a plan with a decimal VID and PID:

```bash
vid=13623
pid=4112
/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless controller output list
/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless controller output plan "$vid" "$pid"
```

The variables use the GameSir G7 SE decimal VID/PID as an example. Replace them with the decimal identifiers printed by `controller output list`.
Each list entry also includes an opaque `device` identifier. VID/PID is enough when
one matching controller is connected. If identical models are connected, append
`--device <id>` to `plan` and every output command. Ambiguous commands are rejected; no arbitrary controller is selected.

The identifier is valid only for the current runtime session. Do not record it
as hardware evidence.

The `controller output` CLI provides controls based on the device capabilities.
Its `plan` command prints the same generated validation steps. A redacted support
report includes plans for connected devices with implemented output
capabilities.

## Record Results

Run one step at a time. Record pass or fail, the controller model, connection
type, and relevant firmware version. If output behaves unexpectedly, stop and
disconnect the controller. One passing step does not verify another actuator or lighting feature.

For controllers with conventional rumble capabilities, the interactive Just
recipe runs each exposed four-channel position in a fixed order and sends an
explicit all-zero stop between steps and when interrupted:

```bash
just diagnose-rumble-motors 13623 4112 160 500
```

The example uses decimal VID `13623`, PID `4112`, intensity `160`, and a 500 ms duration. Replace the first two values with the connected device's decimal IDs. Report each numbered result as left trigger, right trigger, left grip, right
grip, none, or another exact observation. The recipe is a convenience around
the installed app's canonical `controller output rumble` command; it does not
change the documented support status automatically.

The generated plan excludes serial values, HID locations, packet payloads, and
filesystem paths. Review any free-form issue text or attachments separately
before publishing them. The command reports implemented capabilities, not a
machine-authored verification level; accepted observations remain in the
matching testing document and issue history.
