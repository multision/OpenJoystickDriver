# Remapping Input Samples

This page defines motion, touch, extra-control, and paired-controller input. Start with the [remapping overview](remapping.md).

## Motion And Touch Sample Transport

DS4 and DualSense parsers append typed raw gyroscope, accelerometer, and touch frames to
control events. Normalization preserves repeated samples and their relative order while retaining
control-state coalescing. Snapshot control state retains the latest complete frame for each
explicit surface so native capture can detect a new contact; payloads without that field decode
to no touch samples. Compatibility output continues to ignore sample variants.

The packet layout and touch dimensions follow
[Linux hid-playstation at the reviewed revision](https://github.com/torvalds/linux/blob/893e11787f78e43b534e252249ac3fff4d1333f8/drivers/hid/hid-playstation.c).
Sensor vectors retain signed ADC values; they are not calibrated degrees per second or gravity
units. Timestamps retain the raw device counter, rational nanoseconds per tick, elapsed time from
the first report, and a parser-session sequence index. DS4 uses a 16-bit counter at 16000/3 ns;
DualSense uses a 32-bit counter at 1000/3 ns. Fractional remainders carry between samples.
A counter decrease denotes one wrap. This assumes ordered reports; a device reset or multiple
wraps during a gap cannot be distinguished from the counter alone. Reconnection needs a fresh
parser session, and fusion must handle discontinuities before these clocks drive motion output.

Touch frames retain two contacts, active flags, contact IDs, and raw coordinates. DS4 retains
up to three USB or four Bluetooth history frames in packet order, including each raw touch
counter. That counter has no assigned time unit. Its containing-report timestamp does not date
individual historical frames. Malformed history counts omit touch history while preserving
valid motion data. Short DS4 control-only reports emit no synthetic sensor samples.

Focused tests cover signed decoding, counter wrap and fractional ticks, repeated sample delivery,
touch history, short reports, and DualSense Bluetooth CRC rejection before sensor-clock updates.
The active parser exposes `physicalInputCapabilities` through the existing connected-device
payload: raw motion support and maximum contacts per touch frame. This describes decoding, not
calibrated motion or hardware validation. Payloads from an older service default to
no sample capability. Tests exercise both DS4 revisions, DualSense, and DualSense Edge through
the device manager and the encoded payload, preserving the runtime device identifier.

Factory calibration for the supported families is applied before remapping. Other controller
families do not advertise calibrated motion; physical validation remains external. Nintendo timing
uses explicit estimation:
[Linux hid-nintendo](https://github.com/torvalds/linux/blob/893e11787f78e43b534e252249ac3fff4d1333f8/drivers/hid/hid-nintendo.c)
documents that reports lack a reliable sample timestamp and contain three IMU samples.
The Switch Pro parser decodes all three signed raw samples in wire order and requests IMU
enablement (`0x40`, value `1`) during HID startup. It advertises raw motion decoding through the
same capability contract. Short control-only reports do not advance its sensor clock.

The pipeline captures host receipt time before parsing and supplies it through the shared parser
hook. Nintendo timestamps have `hostEstimate` basis, retain the raw report counter as metadata,
and leave device tick units absent. The first report uses nominal 5 ms sample spacing; subsequent
spacing follows a bounded moving average of host report intervals. Backward receipt times clamp,
and gaps above 30 ms preserve elapsed gaps rather than stretching three samples across the gap.
This estimates rather than measures hardware sample timing. Device-counter timestamps retain their distinct
`deviceCounter` basis. Tests cover both parser dispatch paths, sample order, signed values,
backward receipt time, long gaps, short reports, and the IMU startup command.

### Steam Controller Full-State Motion

The Steam Controller parser decodes raw accelerometer and gyro vectors from full state messages
(type `0x01`), following the packet fields used by
[SDL's Steam HID parser](https://github.com/libsdl-org/SDL/blob/634dff3725b8419902b832d1c84363da211a3596/src/joystick/hidapi/SDL_hidapi_steam.c)
and the layout documented in
[Linux hid-steam](https://github.com/torvalds/linux/blob/893e11787f78e43b534e252249ac3fff4d1333f8/drivers/hid/hid-steam.c).
Startup settings request raw accelerometer and gyro output with IMU mode `0x18`; shutdown retains
the existing default-settings restoration. Raw motion is exposed in parser capabilities.

Packet sequence numbers remain metadata. Motion timestamps use host receipt time relative to the
first accepted motion report, clamp backward receipt times, and have no device tick units.
An immediately repeated sequence number does not emit another motion sample. Counter wrap accepts
the next report. Receiver disconnect/connect transitions reset timing and duplicate tracking;
reports received while disconnected do not advance motion state.

This covers full-state packets on the supported wired/receiver path. BLE chunked packets are not
advertised as supported input; hardware delivery validation remains external. Tests establish
raw decoding and lifecycle behavior, not calibrated physical units or wireless firmware delivery.

### Steam Trackpad Samples

Full state packets emit separate `left` and `right` touch surfaces. The shared contact
coordinates are signed 32-bit values. Each frame describes its coordinate origin and dimensions:
Steam pads retain raw signed 16-bit coordinates with origin -32768 and span 65536; Sony frames
retain their zero origin and existing pixel dimensions on the `primary` surface. Contacts use
surface-local IDs, so matching ID zero on two pads does not merge them.

The left axis pair alternates between pad and stick when both are active. Pad packets retain the
last stick value, and interleaved stick packets retain the last pad coordinates. Ending stick
activity neutralizes its contribution. Releasing a pad emits an inactive contact frame. Receiver
lifecycle resets clear remembered pad coordinates along with the motion clock. These rules follow
the full-state interleaving logic in the reviewed SDL source above.

This path also fixes stick/pad cross-contamination; physical validation remains pending.

### Touch Mappings

Profiles identify `primary`, `left`, and `right` surfaces explicitly. Discrete sources cover the
contact lifecycle, a validated 1-by-1 through 16-by-16 grid cell, and a cardinal swipe with a
minimum normalized travel distance. CLI source forms are `touch:<surface>:contact`,
`touch:<surface>:grid:<columns>:<rows>:<zero-based-column>:<zero-based-row>`, and
`touch:<surface>:swipe:<direction>:<minimum-distance>`. Native capture detects a newly active
surface and its manual assignment controls expose grid dimensions, cell coordinates, and swipe
distance. Touchpad and Steam pad clicks remain distinct physical button sources; a contact never
synthesizes a click.

One optional continuous mapping per surface selects relative pointer output or a left/right
virtual touch stick. Pointer sensitivity is measured in logical screen points per complete
surface span. A touch-stick radius is a normalized surface fraction; its radial deadzone and
output are normalized to 0...1 and -1...1 respectively. Continuous mappings are configurable in
the CLI and native profile editor. Touch-stick modes require virtual output policy.

Runtime state is owned by an exact controller and surface. Contact IDs are never compared across
those boundaries. The lowest active contact starts as the primary contact and remains primary
until it ends; changing contact, geometry, profile, or controller session resets the pointer and
stick baseline. A complete inactive frame releases contact/grid bindings and neutralizes touch
stick output. Swipes fire once when their primary contact ends. Profile replacement, disconnect,
permission suspension, shutdown, and failed delivery use the engine's ordinary drain path, which
releases touch-owned buttons and virtual contributions. Tests cover surface and device isolation,
origin-aware geometry, grid transitions, swipes, pointer reset, virtual neutralization, capture,
CLI parsing, profile validation, persistence, and RPC transport.

### Steam Grips And Pad Clicks

Steam full-state packets expose left/right grip and left/right pad-click events as distinct
physical controls. Schema-3 profiles accept `button:left_grip`, `button:right_grip`,
`button:left_pad_click`, and `button:right_pad_click` in the CLI and native source/capture menus.
They can use the existing binding behaviors, chords, sequences, and layers. New source identifiers
require schema 3. The labels have first-pass translations across the current catalogs; visual,
VoiceOver, and native-language review remain pending.

These are input sources, not new virtual buttons. Validation rejects them
as `gamepad_button` destinations, destination menus omit them, and virtual-state construction
filters them. The Steam right-pad click preserves its existing right-stick-click compatibility
output when passed through without a binding. A schema-3 binding consumes that contribution.

Tests cover parser press/release edges, source persistence, key press/release output, invalid
virtual destinations, capture, source menus, and catalog consistency.
Physical isolation and delivery still require hardware validation.

### Independent Joy-Con Input

The canonical HID catalog selects left and right Joy-Con layouts for Nintendo
`057e:2006` and `057e:2007`. Each layout ignores the absent stick and the other half's
button bits, exposes its one rumble motor, and uses Nintendo's three-sample raw IMU path.
Startup requests full input reports and enables IMU and rumble without the Pro Controller's
USB handshake prefix. Both the schema and runtime decoder reject conflicting side selections.

Catalog records were generated from the locked Linux source. Constructed packet tests cover
selection, side filtering, raw sample delivery, startup, and rumble isolation. See
[Joy-Con validation](../testing/joy-con.md) for the exact source and hardware acceptance steps.

### Paired Joy-Con Sessions

Schema-3 profiles targeting the left Joy-Con model can opt into `joy_con_pair` and select the
left, right, or no gyro. Pair profiles do not run on a standalone half. The CLI uses
`map joy-con pair <profile> --left <runtime-identifier> --right <runtime-identifier>`; the native
profile screen exposes the same exact connected-controller selection. Runtime identifiers are
opaque and process-local, so pairing is an explicit in-memory session rather than persistent
hardware identity.

Both halves feed one remapping state and one virtual output identity, using the left half as the
session output key. Nintendo's parser normalizes left and right IMU readings into the stable
combined-controller frame before the configured half reaches calibration and gyro routing. The
unselected half's motion samples are discarded; buttons, the left and right sticks, and rail
controls remain side-owned inputs. Existing Nintendo output reports retain per-half rumble bytes.

Disconnecting either exact member, unpairing, or starting a profile-library transaction drains the
combined output, retires the virtual controller, and cancels the session. A still-connected half
returns to its independent compatibility route. Reconnection requires a new explicit pair, and an
old session UUID cannot unpair its replacement. Constructed routing tests cover partial
availability, combined controls, gyro selection, disconnect, replacement-session isolation, and
profile transaction cleanup. Bluetooth hardware acquisition, physical orientation accuracy,
per-half rumble delivery, and virtual consumer recognition remain unverified.

Joy-Con rail buttons expose four schema-3 sources: `button:left_sl`, `button:left_sr`,
`button:right_sl`, and `button:right_sr`. Each belongs to its physical half, including when
both halves are connected. The Pro Controller layout ignores these bits. Rail sources can map
to supported gamepad buttons or system actions; they have no direct virtual button identity.

### DualSense Edge Controls And Extra-Button Capabilities

The generated Edge record (`054c:0df2`) selects `edgeButtons` for both registry construction
and live HID discovery. Standard DualSense (`054c:0ce6`) keeps its original system-button map.
Edge function buttons and paddles expose `button:left_function`, `button:right_function`,
`button:left_paddle`, and `button:right_paddle` in schema-3 profiles and native capture/editor
controls. They map to existing output destinations; they are not virtual button destinations.

The field masks follow the
[reviewed SDL PS5 parser](https://github.com/libsdl-org/SDL/blob/0c8feecce6e57a7a8c1b1eb06631e0a7a56fcd8f/src/joystick/hidapi/SDL_hidapi_ps5.c).
Constructed USB/Bluetooth reports test each source through gamepad press/release, repeated
report suppression for digital edges, ordinary-model exclusion, and CRC rejection before
button-state mutation. These tests do not establish Edge firmware or hardware delivery.

`physicalInputCapabilities.additionalButtons` carries the parser's extra physical button
identifiers through the connected-device payload. Sony touchpad/mute, Steam grips/pad clicks,
Joy-Con rail controls, and Edge function/paddle controls are reported by their selected parsers.
An older capability payload without the list decodes as an empty list. Base gamepad controls
remain implicit. The list describes decoding, not physical verification or virtual output identities.

`physicalInputCapabilities.touchSurfaces` enumerates the identifiers emitted by touch frames:
Sony exposes `primary`, and Steam exposes `left` and `right`. Nintendo exposes no touch surfaces.
An older payload without this list decodes as unspecified (an empty list), even if it has a
nonzero contact count; clients must not invent a surface identity from that count. Frame geometry
continues to carry coordinate origins and dimensions. Tests compare capabilities with actual
parser-produced frames and preserve the metadata through device-payload serialization.
