# Controller Diagnosis And Evidence

Load this runbook for exact discovery, record-probe, packet, reconnect, or physical-output work. The stable project procedures are `docs/testing/controller-record.md`, `docs/testing/physical-output.md`, and the device-specific pages under `docs/testing/`.

## Evidence Ledger

Record each claim independently:

| Claim | Minimum physical observation |
| --- | --- |
| Discovery | Exact VID/PID, transport, mode, interface, and stable presence |
| Input | Neutral plus press/release or full axis sweep |
| Reconnect | Disconnect, rediscovery, handshake, and representative input |
| Rumble | Each claimed actuator identified separately |
| Player LED or RGB | Each claimed pattern or color observed |

Use **source-backed** when implementation or upstream evidence exists, **hardware-verified** only for the observed claim, and **unavailable** when no implemented path or exposed capability exists.

## Discovery

Capture decimal and hexadecimal VID/PID, connection mode, configuration, interface, endpoint direction, report ID, and report length. Do not infer any value from a similar PID. Note Steam or kernel ownership, permissions, signing, and whether the device appears only after pairing.

The raw record probe supports raw USB GIP and wired or wireless-receiver Xbox 360 records. A missing HID or Bluetooth device in that probe does not establish protocol incompatibility.

## Validate And Probe A Record

Keep the candidate outside bundled records. Validate without opening hardware:

```bash
./Scripts/ojd diagnose record /tmp/controller-candidate.json --validate-only
```

Expected marker: `RECORD_VALIDATION result=valid`.

With authorization for a live USB probe, use a bounded run:

```bash
./Scripts/ojd diagnose record /tmp/controller-candidate.json --seconds 30
```

Review `RECORD`, `USB_DEVICE`, `USB_CLAIM`, `RECORD_HANDSHAKE`, `USB_TX`, `USB_RX`, `EVENT`, `CONTROLLER_CONNECTION`, `PARSE_ERROR`, `RECORD_SUMMARY`, and `USB_KEEPALIVE` lines. Stop on power loss, handshake failure, zero packets, repeated parse errors, or stale events.

A busy interface may be retried once with `--detach`. Record its use and reconnect afterward.

## Review Packets

For each control sequence, preserve a redacted timestamped excerpt and record:

1. report ID, envelope, and observed length;
2. sequence, counter, checksum, or acknowledgement behavior;
3. button, hat, trigger, stick, sensor, or Guide field exercised;
4. startup, keep-alive, or output dependency; and
5. parser event and final normalized state.

Run parser regression evidence separately:

```bash
./Scripts/ojd test parsers-macos14
```

This proves only the checked parser fixtures and local package behavior.

## Physical Output

With a current installed app, list capabilities before sending output:

```bash
vid=13623
pid=4112
/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless controller output list
/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless controller output plan "$vid" "$pid"
```

The variables use the GameSir G7 SE decimal VID/PID as an example. Replace them with decimal identifiers from the current controller record. If identical devices are connected, use the current session's opaque `--device` value but do not record it as a durable identity. Run one plan step at a low bounded value and stop on unexpected behavior. A plan or successful packet write does not prove a physical actuator worked.

## Failure Meanings

| Observation | Safe conclusion |
| --- | --- |
| No native or OJD listing | No discovery evidence in this session |
| Listed but busy | Another owner may hold the interface |
| Record invalid | Candidate violates the record contract |
| Handshake failure or power loss | Declared startup is not accepted |
| Zero `USB_RX` | No input evidence |
| Packets plus parse errors | Parser and observed framing disagree |
| Missing or wrong events | Input claim is not proven |
| Reconnect loses lifecycle | Reconnect claim is not proven |
| Output plan absent or step fails | That output capability is unverified |

## Handoff Fields

Record controller and VID/PID, transport and mode, OJD revision, macOS, firmware if known, exact commands and durations, detach use, handshake and summary lines, control matrix, reconnect result, per-actuator result, evidence class per claim, redactions, and remaining risks. Never publish serials, stable user paths, session IDs, or unredacted captures.
