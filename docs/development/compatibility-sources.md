# Compatibility Source Notes

External projects provide design or protocol evidence, not runtime dependencies
or proof of macOS hardware support. Relevant archived SDL discussions live
under `docs/external/sdl/`.

## Admission Policy

- Select Flydigi, GameSir, XID, XUSB, GIP, or another specialized parser only
  for an exact cataloged VID/PID, transport, and protocol variant.
- Keep uncataloged standards-compliant HID descriptor-driven and Generic HID.
  Never infer a vendor protocol from a brand, vendor ID, or nearby product ID.
- A historical device list can corroborate an identity but cannot admit it.
  `0E4C:3240` and `FFFF:FFFF` remain unadmitted.
- Derive physical output capabilities from the selected parser. Protocol byte
  fixtures establish source-backed behavior; hardware verification requires a
  matching physical run.

## Pinned XID And XUSB Evidence

- [Xbox360Controller `9aa224a`](https://github.com/xdccrlz/Xbox360Controller/tree/9aa224a89732cc42d2955762b47d8a5a281de75f):
  [`Controller.cpp`](https://github.com/xdccrlz/Xbox360Controller/blob/9aa224a89732cc42d2955762b47d8a5a281de75f/360Controller/Controller.cpp),
  [`ControlStruct.h`](https://github.com/xdccrlz/Xbox360Controller/blob/9aa224a89732cc42d2955762b47d8a5a281de75f/360Controller/ControlStruct.h),
  and [`LICENSE`](https://github.com/xdccrlz/Xbox360Controller/blob/9aa224a89732cc42d2955762b47d8a5a281de75f/LICENSE)
  are the licensed implementation reference for original-Xbox input and rumble
  framing. OJD's encoder is independent and covered by byte fixtures.
- [Xb2XInput `8f4187a`](https://github.com/emoose/Xb2XInput/tree/8f4187a23ecd834961151fb68b7a17334820986b):
  [`README.md`](https://github.com/emoose/Xb2XInput/blob/8f4187a23ecd834961151fb68b7a17334820986b/README.md),
  [`XboxController.hpp`](https://github.com/emoose/Xb2XInput/blob/8f4187a23ecd834961151fb68b7a17334820986b/Xb2XInput/XboxController.hpp),
  and [`XboxController.cpp`](https://github.com/emoose/Xb2XInput/blob/8f4187a23ecd834961151fb68b7a17334820986b/Xb2XInput/XboxController.cpp)
  corroborate XID framing and historical IDs only; they are not implementation
  or admission authority.
- [ViGEmBus `d986e1d`](https://github.com/nefarius/ViGEmBus/tree/d986e1d93708ec9b11049542fa6027272cce716c):
  [`README.md`](https://github.com/nefarius/ViGEmBus/blob/d986e1d93708ec9b11049542fa6027272cce716c/README.md)
  and [`sys/XusbPdo.cpp`](https://github.com/nefarius/ViGEmBus/blob/d986e1d93708ec9b11049542fa6027272cce716c/sys/XusbPdo.cpp)
  describe a virtual XUSB target, not physical admission.
- [VDX `fb11124`](https://github.com/nefarius/VDX/tree/fb11124017f499adcc7c129822aef9bec80d3174):
  [`README.md`](https://github.com/nefarius/VDX/blob/fb11124017f499adcc7c129822aef9bec80d3174/README.md)
  and [`src/Main.cpp`](https://github.com/nefarius/VDX/blob/fb11124017f499adcc7c129822aef9bec80d3174/src/Main.cpp)
  demonstrate input mirroring to selected virtual output.
- [XInputHooker `f31d644`](https://github.com/nefarius/XInputHooker/tree/f31d64470831ac39644dc088e632898afa4dd926):
  [`README.md`](https://github.com/nefarius/XInputHooker/blob/f31d64470831ac39644dc088e632898afa4dd926/README.md),
  [`XUSB.h`](https://github.com/nefarius/XInputHooker/blob/f31d64470831ac39644dc088e632898afa4dd926/XInputHooker/XUSB.h),
  and [`XInputHooker.cpp`](https://github.com/nefarius/XInputHooker/blob/f31d64470831ac39644dc088e632898afa4dd926/XInputHooker/XInputHooker.cpp)
  describe Windows XUSB discovery and IOCTL capture, not an OJD route.

## Current Evidence Boundaries

- Pinned Linux `xpad.c`, `hid-playstation.c`, `hid-sony.c`,
  `hid-nintendo.c`, and `hid-steam.c` establish protocol or identity facts, not
  macOS descriptors, endpoints, TCC behavior, or hardware success.
- GameSir `3537` records combine exact Linux identities with
  [`gamesir-linux-tools`](https://github.com/broroeror/gamesir-linux-tools/blob/main/RESEARCH.md)
  packet research. Shared Microsoft Bluetooth IDs are not attributed to GameSir
  without exact captures.
- [Issue 33](https://github.com/xsyetopz/OpenJoystickDriver/issues/33) verifies
  SCUF Envision Pro `2E95:434D` report-6 core input only. It does not establish
  extra buttons, paddles, output, or wireless behavior; `2E95:0504` stays GIP.
- SDL HIDAPI and mappings inform consumer identity and button order only.

## Gates

```bash
./Scripts/ojd catalog regenerate --check
./Scripts/ojd check profiles
./Scripts/ojd check schemas
./Scripts/ojd test parsers-macos14
swift test
```

Before adding transport or output, record lifecycle, framing, ownership,
failure behavior, protocol fixtures, and a separate hardware plan. Before
adding a spoof identity, record the exact descriptor, report bytes, and consumer.
