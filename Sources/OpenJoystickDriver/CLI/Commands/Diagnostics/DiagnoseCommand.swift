import Foundation
import OpenJoystickDriverKit
import OpenJoystickDriverUSB

struct DiagnoseCommand {}

struct DiagnoseUSBScanFailure: Error, Sendable { let message: String }
