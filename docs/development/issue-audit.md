# Controller Issue Audit

This audit separates implemented behavior from observations on reported
hardware. Passing repository tests does not replace the physical-controller
procedures linked below. GitHub issues remain authoritative if this page becomes
stale.

Audit baseline: 2026-09-15, beta.4 implementation through `0007872`.

## Beta.4 Classification

| Item | Implemented evidence | Release action | Remaining closure evidence |
| --- | --- | --- | --- |
| [#8 Steam Controller](https://github.com/xsyetopz/OpenJoystickDriver/issues/8) | The catalog, parser, feature-report discovery, receiver lifecycle, and parser harness cover the wired and wireless Valve identities. | Keep open. | Run the [wired and wireless hardware procedure](../testing/steam-controller.md), including reconnect and consumer visibility. |
| [#9 Xbox 360 wireless](https://github.com/xsyetopz/OpenJoystickDriver/issues/9) | Receiver records, wrapped-input parsing, lifecycle handling, and output-packet tests cover `045E:0291`, `02A9`, and `0719`. | Keep open. | Run the [receiver procedure](../testing/xbox-360-wireless-receiver.md) through direct IOUSBHost and determine whether macOS ownership requires a DEXT entitlement. |
| [#11 Logitech F310](https://github.com/xsyetopz/OpenJoystickDriver/issues/11) | The `046D:C21D` XUSB record has captured interrupt endpoints and mapping tests. | Keep open. | Run the [F310 procedure](../testing/logitech-f310.md) and compare every control with SDL on the same Mac. |
| [#14 Wolverine V3 TE](https://github.com/xsyetopz/OpenJoystickDriver/issues/14) | The local `1532:0A43` record selects GIP without claiming unobserved controls or output. | Keep open. | Complete the [V3 TE procedure](../testing/razer/v3-te.md), including startup, input, reconnect, indicator, and rumble. |
| [#18 Xbox One 1537](https://github.com/xsyetopz/OpenJoystickDriver/issues/18) | The `045E:02D1` GIP record contains the verified configuration and endpoints; parser and admission tests pass. | Keep open. | Use a provisioned build to open the controller through the generated DEXT and complete the [1537 procedure](../testing/xbox/1537.md). |
| [#19 Wolverine V2](https://github.com/xsyetopz/OpenJoystickDriver/issues/19) | The `1532:0A29` record selects GIP on the captured interface and endpoints. | Keep open. | Complete the [Wolverine V2 procedure](../testing/razer/wolverine-v2.md), including reconnect, indicator, and rumble. |
| [#21 Nacon Revolution X Pro](https://github.com/xsyetopz/OpenJoystickDriver/issues/21) | The local GIP record contains the captured endpoints and disables the unsupported synthetic host-status packet; framing and acknowledgement tests cover the implemented protocol behavior. | Keep open. | Run the [Nacon procedure](../testing/nacon-revolution-x.md), especially continuous input and reconnect. |
| [#22 ZD Ultimate Legend](https://github.com/xsyetopz/OpenJoystickDriver/issues/22) | Device-first IOUSBHost discovery handles `bDeviceClass = 0`, and the controller's physical output uses its observed interrupt OUT endpoint. | Close after the beta.4 release and release notes are verified. | Confirm discovery, input, player indicator, and rumble on `413D:2104` from the published build. Reopen or file a focused follow-up if hardware testing fails. |
| [#31 WR-007](https://github.com/xsyetopz/OpenJoystickDriver/issues/31) | The `11C1:5600` record maps the captured sparse buttons, sticks, and analog triggers and permits Apple GameController publication. | Keep open. | Run the [WR-007 procedure](../testing/wr-007.md) with a signed build and verify consumer-visible input. |
| [#32 wired Xbox 360 beta.3 regression](https://github.com/xsyetopz/OpenJoystickDriver/issues/32) | Beta.4 replaces the virtual-output lifecycle path and clears stale controller state before a new physical session. | Keep open. | Verify the original wired controller in the input tester and in Steam using the published signed build, including disconnect and reconnect. |
| [#33 SCUF Envision Pro](https://github.com/xsyetopz/OpenJoystickDriver/issues/33) | The exact `2E95:434D` record discovers report 6 through both HID backends and maps the reported sticks, triggers, buttons 1–10, and hat. | Keep open. | Complete the [SCUF procedure](../testing/scuf-envision-pro.md) in a signed build. Unmapped controls, output, and wireless operation require separate evidence. |

There is no known release-blocking implementation defect in this set. The ten
items marked **Keep open** require signed-build or hardware confirmation, not
more unit-test evidence.

## Pull-Request Reconciliation

Pull requests [#24](https://github.com/xsyetopz/OpenJoystickDriver/pull/24) and
[#30](https://github.com/xsyetopz/OpenJoystickDriver/pull/30) must not be
merged. Their requested Xbox 360/Rock Candy and Flydigi behavior is already
integrated into a substantially changed beta.4 branch. After beta.4 is
published and its release body is verified, leave an item-specific explanation
and close both pull requests as superseded.

The beta.4 release body must credit these integrated contributions under
`What's Changed`:

- [#24](https://github.com/xsyetopz/OpenJoystickDriver/pull/24) by
  `@elijahtheprophet24`;
- [#30](https://github.com/xsyetopz/OpenJoystickDriver/pull/30) by `@scraton`;
- [#31](https://github.com/xsyetopz/OpenJoystickDriver/issues/31) by
  `@arthurknowles34-a11y`;
- [#33](https://github.com/xsyetopz/OpenJoystickDriver/issues/33) by
  `@zoltanerdelyic1`.

All four accounts belong under `New Contributors`. Preserve the
`0.5.0-beta.3...0.5.0-beta.4` Full Changelog link. Follow the
[release reconciliation procedure](releases.md) before commenting on or
closing any hosted item.

## Release Gate

Run `just check` on the exact commit that will be tagged. It covers the catalog,
profiles, schemas, repository tools, DriverKit generation, macOS 14 parsers,
formatters, linters, type checks, repository-script tests, and Swift tests.
Confirm a clean worktree and run `git diff --check` before tagging.

Publishing, tagging, signing, notarization, and asset upload are separate
release actions. A green repository check does not prove any of them.
