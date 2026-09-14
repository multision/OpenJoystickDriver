# Native tools

`SDLGamepadProbe` is the maintained native probe. Build it without opening any
hardware devices:

```bash
./Scripts/ojd check tools
```

It uses Apple Clang, the system `SDL3` package discovered through `pkg-config`,
and the Foundation and GameController frameworks. Run it only when intentionally
testing connected hardware:

```bash
./Scripts/ojd diagnose sdl3 --seconds 10
```

Add `--rumble` only when output to each SDL gamepad is intended.
