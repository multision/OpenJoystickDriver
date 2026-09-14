# Compatibility Modes

Choose the actual consumer's route. Enumeration alone does not prove input works; every route names its protocol family and evidence
status. Automatic routing is conservative. It selects an exact catalog-backed tuple when
one exists. Otherwise it follows the wire-family list: if the physical device is
already a first-party identity that family can publish, keep it; else spoof the closest
official device for that same protocol. XUSB clones publish Microsoft
`045E:028E`. GIP clones normally publish Xbox Series `045E:0B13`; Automatic
uses Xbox One S `045E:02E0` while a Gecko browser is frontmost. DualShock 4, DualSense,
and Switch Pro physical HID pads publish their first-party USB identities
automatically. Other HID stays Generic HID. Steam and Flydigi stay Generic HID.
XID (original Xbox USB) is parsed in userspace and is not HID. DualShock 1/2 used the
PlayStation controller port, not USB HID. Frontmost-app lists do not gate this.
Never cross families automatically: GameSir G7 SE does not become an Xbox 360
pad or ASTRO C40. Explicit picker/CLI may publish a first-party packer
identity for live consumer-bind, then return to automatic.

Automatic identifies browser engines from browser-role metadata and bundled
engine files. It does not use browser names or bundle identifiers. Unknown or
ambiguous browser fingerprints use the canonical Blink-verified Xbox Series
variant. SDL routing is detected separately from bundled Mach-O dependencies.
Compatibility reports continue while the device is active; foreground changes
only trigger transactional Automatic variant transitions.

Status marks appear only in the support lists below:

- ✅ hardware-verified for the named physical mode and consumer
- ⚠️ source-backed candidate; live consumer evidence still required
- 🧪 reported failure or experimental result; never auto-selected
- 🔬 research-only; no production spoof
- ❌ unavailable

## Choose An Identity

### SDL2-3

Use for applications that consume SDL 2 or SDL 3 HIDAPI. Stock Steam-bundled
and Homebrew SDL `hid_init` still hang if an Apple `AppleGCSyntheticDevice`
`GamePad-1` leftover is already wedged: SDL matches all HID devices, then
`IOHIDDeviceCreate` `IOServiceOpen`s the GameController plugin. OJD no longer
opens that node. A leftover shim outlives OJD and is not removed without
reboot or `gamecontrollerd` restart. This is not a Steam bind result. The virtual device publishes Microsoft
Xbox 360 Wired `045E:028E` with Xbox 360 HID reports. XUSB clones that are
missing from SDL HIDAPI's device list use this first-party identity. ASTRO C40 `9886:0024` is a DualShock-style
third-party pad and is not a spoof target. Automatic routing does not select
this identity for GIP; use `apple-gamecontroller` for Series. Explicit
picker/CLI may publish `045E:028E` from GIP for live bind.

### Apple GameController

Use only to test native applications that read `GCController`. This selectable
route uses the Xbox Series Bluetooth tuple `045E:0B13`. Its primary input report
includes the Consumer Record usage that GameController.framework exposes as
`GCXboxGamepad.buttonShare`. View and Share remain separate inputs. Selecting
it does not republish the foreground identity or create a second virtual device.

GameController clients control macOS controller gestures. If an app leaves a
gesture enabled, macOS may delay View or reserve Guide and Share. The OJD probe
can disable those gestures for its own test, but OJD cannot change another
app's gesture settings.
`GCController.supportsHIDDevice`, connect, extended-profile, input, and
reconnect results are diagnostic evidence, not guarantees. Do not claim
haptics without a physical/runtime observation.

### DualShock 4

Use to test SDL HIDAPI PS4 and Apple GameController DualShock 4 consumers.
Publishes Sony `054C:09CC` "Wireless Controller" with USB report `0x01`.
Automatic when the physical pad is DualShock 4. Explicit picker may publish
this identity from another family for live bind.

### DualSense

Use to test SDL HIDAPI PS5 and `GCDualSenseGamepad` consumers. Publishes Sony
`054C:0CE6` "Wireless Controller" with USB report `0x01`. Automatic when the
physical pad is DualSense. Explicit picker may publish this identity from
another family for live bind. macOS 11.3+ for native DualSense GameController.

### Switch Pro

Use to test SDL HIDAPI Nintendo and Apple GameController Switch Pro consumers.
Publishes Nintendo `057E:2009` "Pro Controller" with USB report `0x30` and the
USB `0x80`/`0x81` handshake. Automatic when the physical pad is Switch Pro.
Explicit picker may publish this identity from another family for live bind.

### Generic HID

Use for unknown or unsupported consumers that fit none of the specialized
profiles. The descriptor exposes a plain, non-spoof gamepad as `4F4A:4449`
`OpenJoystickDriver Generic HID Gamepad`. This identity provides device-neutral,
lossless raw input; it does not guarantee browser `mapping: "standard"`.
Sticks occupy axes 0–3, LT/RT occupy the positive halves of axes 4–5, and
digital controls use B0–B5/B8–B17 without duplicated trigger buttons or a
D-pad axis. Vendor-specific controls may be absent. This layout and identity are
stable; an incompatible future layout requires a new PID.

### Xbox 360 HID

Use only for a consumer that needs the OJD Xbox 360-family HID descriptor and
report shape. This is a generic HID compatibility profile, not Windows XUSB22.sys
or XInput. It uses the OJD Xbox 360 HID report format and remains
research-only until a named consumer is tested.

Set an explicit identity from the installed CLI:

```bash
/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless compat set sdl2-3
/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless compat set apple-gamecontroller
/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless compat set dualshock4
```

Only explicit identities guarantee persistence: successful selections are stored
and rebuilt on service startup. With `automatic`, the persisted value is
the automatic intent, not a fixed identity. Foreground-consumer routing may
replace or retire the per-controller user-space backend at runtime and does not
persist the detected engine, VID/PID variant, or other temporary choice.

## Controller Support

### ✅ Hardware-Backed Paths

- GameSir G7 SE through GIP, including four-motor output
- SCUF Envision Pro wired `2E95:434D` report-6 controls recorded in issue 33:
  sticks, independent triggers, buttons 1–10, and hat
- Flydigi Vader 5S through GIP; the record sets USB configuration 1 before claim
- DualShock 4 USB and Bluetooth input, rumble, and RGB lightbar
- Xbox 360 USB parsing; individual model coverage still varies

### 🚧 Source-Backed Paths Needing Hardware Checks

- GameSir G7 Pro USB `3537:1003`, `105D`, `105E`, `109B`, `109C`, and `10BA`
  with standard XInput gameplay plus the vendor telemetry stream; documented
  dock brightness becomes available only after the configuration-ready stream
- GameSir Cyclone 2 enhanced HID `3537:0575`, `100B`, and `1053`, including
  heartbeat, extras, battery, motion, two-motor rumble, and solid RGB/brightness
- GameSir G7 Pro 8K PC enhanced HID `3537:10C5`–`10C8`, including heartbeat,
  extras, battery, motion, two-motor rumble, and home-ring color/brightness
- DualShock 3 USB and Bluetooth input, operational-mode setup, two motors, and player LEDs
- DualSense USB and Bluetooth input, compatible rumble, player LEDs, and RGB lightbar
- Steam Controller wired and wireless input, lifecycle, trackpad haptics, and LED brightness
- Switch Pro USB and Bluetooth input, startup reports, HD rumble, and player LEDs
- Linux xpad-derived Xbox records that have not been tested on their matching hardware

### ⚠️ Fallback And Consumer Limits

- Generic HID maps descriptor-defined controls but cannot infer vendor protocols.
- Restricted raw-USB models require the signed DriverKit extension; accessible vendor-specific devices use direct IOUSBHost.
- Automatic routing never crosses protocol families. When no verified adjacent identity exists, OJD uses Generic HID.
- Browser engines may map the same identity differently. Enumeration, input, reconnect, and output are separate claims.
- Exact consumer-bind observations, failures, and hardware limits are in [consumer-binding evidence](../testing/consumer-binding.md).

## Browser Gamepad API Testing

**ControllerTest.io is the canonical manual browser test site**:

**<https://controllertest.io/>**

Run each matrix row from a clean browser document and record the exact browser
version, Gamepad `id`, mapping, slot/count, every button and axis, timestamps,
disconnect/reconnect behavior, and exposed actuator fields. One browser's result does not establish another's support;
neither enumeration nor rumble alone proves support.
Generic HID is expected to use `mapping: n/a`, with sticks on axes 0–3,
analog LT/RT pressure on axes 4–5, and digital controls on B0–B5 and B8–B17.
Digital-only trigger sources use full-scale values on axes 4–5. It intentionally
does not expose B6/B7 or a D-pad axis.
See the [browser test protocol and reported observations](../testing/browser-gamepad-api.md).

### ❌ Not Implemented

Bluetooth support does not extend to arbitrary controllers. The ASTRO C40 PS4
mode `9886:0025` is experimental research only: the repository lacks a
complete descriptor, feature/calibration, input, and output contract, so it is
not a supported spoof route.

Compatibility selection is keyed by **physical protocol family × target
consumer × evidence**. XUSB and GIP inputs may use an Xbox-adjacent
identity only when that consumer evidence exists; the OJD `xbox360-hid` route
is generic HID and is not XUSB22.sys or XInput. Nintendo and PlayStation
inputs require their own adjacent supported identity. Automatic `sdl2-3`
publishes first-party Microsoft `045E:028E` for XUSB pads only. It does not
cross into GIP, DualShock, or Nintendo merely because SDL HIDAPI also has
drivers for those protocols. Explicit picker/CLI may publish a first-party
packer identity on GIP for live bind. When no verified adjacent identity exists, OJD uses generic HID rather than guessing.
Browser reports remain per-engine because Blink, WebKit, and Gecko can map
the same family differently.

| Physical family/mode | SDL/HIDAPI | Apple GameController | Automatic result |
| --- | --- | --- | --- |
| Xbox GIP, exact GameSir G7 SE mode | ⚠️ Series `045E:0B13`; custom HIDAPI xboxone BLE idle rest `0x8000`→0; no physical button; not Steam | ✅ Xbox Series `045E:0B13` | `apple-gamecontroller` |
| Xbox GIP, other modes | ⚠️ first-party Series unless a reported failure tuple exists | ⚠️ Xbox Series profile | first-party Series |
| Xbox 360 physical family | ⚠️ `sdl2-3` (Microsoft `045E:028E`) | 🔬 Series BT not used for 360 | `sdl2-3` |
| XInputHID/XUSB wire protocol | ❌ no macOS emulation claim | ❌ no macOS emulation claim | Generic HID |
| Xbox One Bluetooth `045E:02FD` | 🧪 BT1/BT2 reported no SDL input; route retired | 🔬 use `apple-gamecontroller` or `generic-hid` | Generic HID |
| Nintendo Switch Pro | ⚠️ automatic `switchpro` USB packer; explicit G7 SE publish: custom HIDAPI switchpro `SDL_OpenGamepad` ok, not Steam | ⚠️ automatic `switchpro`; explicit G7 SE `supportsHIDDevice` yes | `switchpro` |
| PlayStation DS4/DS5 | ⚠️ automatic `dualshock4` / `dualsense`; explicit G7 SE publish: custom HIDAPI ps4/ps5 `SDL_OpenGamepad` ok, not Steam | ⚠️ automatic packers; explicit G7 SE `supportsHIDDevice` yes | matching first-party HID |
| Other | 🔬 no cross-family spoof | 🔬 no cross-family spoof | Generic HID |

## Apple GameController Support

Use live detection by `GCController.supportsHIDDevice` and a hardware test to
determine whether the active virtual controller works with
GameController.framework. The `apple-gamecontroller` profile publishes
`045E:0B13`; the OJD probe confirms whether macOS created `GCXboxGamepad`,
`buttonShare`, and any paddle inputs. Browser Gamepad API results are separate:
a browser may omit Share even when native GameController.framework exposes it.
The private current-system mapping catalog is optional. A missing pair does not
prove incompatibility. See
[Xbox fallback identity evidence](../development/xbox-identities.md).

## USB DriverKit Extension

`OpenJoystickDriverUSB` selects between direct app-side IOUSBHost and
`com.openjoystickdriver.XboxUSBDevice`. The DEXT is used only for an observed
DEXT-owned service or an Apple-entitled Microsoft Xbox GIP model; it is not
the generic path for every controller. OJD does not use libusb or publish a
second controller. Development and production DEXT matching are both limited
to the VID/PID pairs in OJD's Apple-issued entitlement. Accessible third-party
controllers, including the GameSir G7 SE, use direct app-side IOUSBHost instead.

Run the shared CLI self-test even while Compatibility mode is active:

```bash
/Applications/OpenJoystickDriver.app/Contents/MacOS/OpenJoystickDriver --headless test 5
```

The self-test checks the current Compatibility virtual-HID backend. For an
explicit identity, that backend is rebuilt from the persisted identity after
service startup. In `automatic` mode, foreground routing may replace or retire
the per-controller backend while the persisted value remains the automatic
intent; the self-test therefore does not prove a universally persistent
backend. On macOS 10.15–14 the active backend uses `IOHIDUserDevice`; on macOS
15 and later it uses CoreHID `HIDVirtualDevice`. A self-test does not prove USB
system-extension approval, signing validity, or behavior on a different macOS
version or hardware.

## App Rumble

OJD forwards app rumble only when the virtual report and physical parser agree on an output format. Supported inputs are Xbox One report ID `3`, the eight-byte Xbox 360 packet, OJD compact report `0x4F`, and DualShock 4 Bluetooth report `0x11`.

Xbox 360 and DualShock 4 use their two main motors. GIP controllers may also use trigger motors. DualShock 4 ignores trigger values.

## Input Integrity

Before a parsed packet reaches an output backend, OJD reduces its events to the packet's final net controller state. It drops duplicate transitions and contradictory press/release pulses that end unchanged. It also emits one canonical D-pad direction, rejects non-finite analog values by retaining the prior component, and clamps sticks to `-1...1` and triggers to `0...1`. This integrity gate does not add a timing delay or a new global deadzone. Protocol-specific deadzones remain in their parsers.

For an explicit identity, the normalized batch is delivered to one persistent
virtual-HID device per physical controller. Focusing or opening a consumer does
not replace that device, so SDL hot-plug state remains stable. In `automatic`
mode, foreground routing may replace or retire the per-controller backend;
only the automatic intent is persisted, not that temporary consumer choice.

## Manual Checks

Before marking a mapping verified, check the exact app and mode:

1. SDL2/3: `A2` and `A5` idle at zero, D-pad releases cleanly.
2. Parsec macOS to Windows: D-pad and A/B/X/Y stay stable on the Windows host.
3. Rumble: app output report reaches the physical controller if the controller supports rumble.
