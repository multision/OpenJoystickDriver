/// Stable identity constants for OpenJoystickDriver-created virtual HID devices.
///
/// These values are used to:
/// - disambiguate our virtual devices from real controllers with the same VID/PID
/// - avoid ambiguous `LocationID=0/1` heuristics in some HID consumers
public enum VirtualDeviceIdentityConstants {
  /// User-space IOHIDUserDevice LocationID namespace.
  ///
  /// We intentionally use a *range* (not a single constant) so we can create one
  /// virtual controller per physical controller without collisions.
  ///
  /// The high 16 bits ("OJ") are a stable namespace. The low 16 bits are derived
  /// (deterministically) from the physical device identifier.
  public static let userSpaceLocationIDNamespace: UInt32 = 0x4F4A_0000  // "OJ" namespace
}
/// Defines the virtual HID device identity presented to the OS.
///
/// Physical input is normalized to the internal virtual-gamepad state; the
/// profile controls the selected HID descriptor and consumer identity.
public struct VirtualDeviceProfile: Equatable, Sendable {
  public let vendorID: Int
  public let productID: Int
  /// Value used for `kIOHIDVersionNumberKey` / SDL "product version".
  ///
  /// SDL includes this 16-bit value in the GUID it uses to look up controller mappings.
  /// For some SDL-based consumers on macOS, having the expected version is required for
  /// automatic mapping to be applied.
  public let versionNumber: Int
  public let productName: String
  public let manufacturer: String
  public let transport: String

  /// OpenJoystickDriver virtual gamepad. This standard HID GamePad identity avoids
  /// triggering device-specific HID parsers in consumers (e.g. SDL's Xbox path).
  public static let openJoystickDriver = Self(
    vendorID: 0x4F4A,  // "OJ"
    productID: 0x4447,  // "DG" (arbitrary, stable)
    versionNumber: 0x0408,
    productName: "OpenJoystickDriver Virtual Gamepad",
    manufacturer: "OpenJoystickDriver",
    transport: "USB"
  )

  /// Stable non-spoof Generic HID identity. Its name, version, descriptor, and report
  /// layout form one consumer contract; incompatible layouts require a new product ID.
  public static let openJoystickDriverGenericHID = Self(
    vendorID: 0x4F4A,
    productID: 0x4449,
    versionNumber: 0x0408,
    productName: "OpenJoystickDriver Generic HID Gamepad",
    manufacturer: "OpenJoystickDriver",
    transport: "USB"
  )

  /// Xbox One S-shaped generic-HID profile for the explicit Apple/Xbox One
  /// compatibility routes. This is not XInputHID, XUSB, or GIP emulation.
  public static let xboxOneS = Self(
    vendorID: 0x045E,
    productID: 0x02FD,
    // Important: SDL mapping DB entry for macOS expects version=0x0000 for GUID
    // `030000005e040000fd02000000000000` (Xbox One Controller, platform: Mac OS X).
    // Matching this makes SDL treat the device as a Gamepad with automatic mappings.
    versionNumber: 0x0000,
    productName: "Xbox Wireless Controller",
    manufacturer: "Microsoft",
    transport: "Bluetooth"
  )

  /// Xbox One S Bluetooth identity whose Firefox remapper matches the native report.
  public static let firefoxXboxOneS = Self(
    vendorID: 0x045E,
    productID: 0x02E0,
    versionNumber: 0x0000,
    productName: "Xbox Wireless Controller",
    manufacturer: "Microsoft",
    transport: "Bluetooth"
  )

  /// Xbox Series Bluetooth identity used by Apple GameController compatibility.
  /// The Series profile adds the Consumer Record input used for Share.
  public static let xboxSeries = Self(
    vendorID: 0x045E,
    productID: 0x0B13,
    versionNumber: 0x0000,
    productName: "Xbox Wireless Controller",
    manufacturer: "Microsoft",
    transport: "Bluetooth"
  )

  /// Xbox 360 Controller (Wired). First-party SDL HIDAPI / `sdl2-3` spoof target
  /// for Xbox 360-family clones.
  ///
  /// `versionNumber` must be non-zero: SDL on macOS treats `045E:028E` version 0
  /// as a Steam virtual gamepad and ignores it unless that path is explicitly
  /// allowed. `0x0114` matches a common wired Xbox 360 `bcdDevice`.
  ///
  /// Many macOS stacks do not treat 045E:028E as a standard HID gamepad.
  public static let xbox360Wired = Self(
    vendorID: 0x045E,
    productID: 0x028E,
    versionNumber: 0x0114,
    productName: "Xbox 360 Wired Controller",
    manufacturer: "Microsoft",
    transport: "USB"
  )

  /// Sony DualShock 4 USB identity (`054C:09CC`). Official product string is
  /// "Wireless Controller". Automatic promotion waits for live consumer bind.
  public static let dualShock4USB = Self(
    vendorID: 0x054C,
    productID: 0x09CC,
    versionNumber: 0x0000,
    productName: "Wireless Controller",
    manufacturer: "Sony Interactive Entertainment",
    transport: "USB"
  )

  /// Sony DualSense USB identity (`054C:0CE6`). Official product string is
  /// "Wireless Controller". Automatic promotion waits for live consumer bind.
  public static let dualSenseUSB = Self(
    vendorID: 0x054C,
    productID: 0x0CE6,
    versionNumber: 0x0000,
    productName: "Wireless Controller",
    manufacturer: "Sony Interactive Entertainment",
    transport: "USB"
  )

  /// Nintendo Switch Pro USB identity (`057E:2009`). Official product string is
  /// "Pro Controller". Automatic promotion waits for live consumer bind.
  public static let switchProUSB = Self(
    vendorID: 0x057E,
    productID: 0x2009,
    versionNumber: 0x0000,
    productName: "Pro Controller",
    manufacturer: "Nintendo Co., Ltd.",
    transport: "USB"
  )

  /// Default profile used when no protocol-specific profile is configured.
  /// Uses the OpenJoystickDriver virtual identity (generic HID GamePad).
  ///
  /// IMPORTANT: Do not default to spoofing a real controller's VID/PID unless
  /// the report descriptor and report bytes exactly match that controller's HID
  /// protocol. Many consumers (notably SDL) switch parsing logic based on VID/PID
  /// and will ignore inputs if the descriptor doesn't match their expectations.
  public static let `default` = openJoystickDriver
}
