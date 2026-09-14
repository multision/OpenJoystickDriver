---
name: debug-controller-openjoystickdriver
description: >-
  Diagnose one physical controller in OpenJoystickDriver through discovery,
  packet, parser, reconnect, or output evidence. Not for catalog authoring or
  implementing product behavior.
---

# Debug A Controller

Produce a repeatable evidence record for one controller and connection mode. Schema or parser checks alone do not prove hardware support.

## Safety

- Ask before destructive writes, installation, system-extension activation, publication, or physical output.
- State which controller may rumble, move, light, or change mode before sending output.
- Redact serial numbers, user paths, signing identities, and tokens. Preserve VID/PID, interface, endpoint, report ID, length, direction, and timing.
- Do not run competing readers. Stop an existing app or probe before claiming the device.

## Procedure

1. Read `AGENTS.md`, the controller record, parser, and matching testing page.
2. Load [diagnosis and evidence](references/diagnosis.md) for exact discovery, record-probe, packet, or output commands.
3. Define one question and success signal, including physical mode and macOS version.
4. Capture the smallest neutral/control/release sequence that distinguishes the behavior.
5. Compare transport bytes, parser events, normalized state, and reconnect behavior without filling unknown bytes by guesswork.
6. For output, enumerate capabilities first and test one channel at a low bounded value.
7. Validate relevant artifacts without claiming unperformed hardware coverage:

   ```bash
   ./Scripts/ojd check profiles
   ./Scripts/ojd test parsers-macos14
   swift test
   git diff --check
   ```

## Handoff

Record the exact command, exit result, device and connection mode, observed bytes/events, expected result, evidence class, redactions, and remaining unknowns. Send catalog changes to `$add-controller-openjoystickdriver` and product fixes to `$maintain-openjoystickdriver`.
