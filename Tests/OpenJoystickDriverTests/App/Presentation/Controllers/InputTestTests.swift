import Combine
import Foundation
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

struct RecordedRumble: Equatable, Sendable {
  let selector: RuntimeDeviceSelector
  let left: UInt8
  let right: UInt8
  let leftTrigger: UInt8
  let rightTrigger: UInt8
  let durationMilliseconds: Int
}

enum InputTestGatewayError: Error { case outputFailed }

actor InputTestGatewayStub: InputTestDeviceGateway {
  func motionCalibration(
    for selector: RuntimeDeviceSelector,
    command: RemappingMotionCalibrationCommand?
  ) throws -> RemappingMotionCalibrationStatus {
    throw RemappingMotionCalibrationError.motionUnavailable
  }
  var inputSequence: [DeviceInputState?]
  var inputDelayNanoseconds: UInt64
  var outputDelayNanoseconds: UInt64
  var inputCalls = 0
  var cancelledInputCalls = 0
  var activeInputCalls = 0
  var maximumConcurrentInputCalls = 0
  var inputSelectors: [RuntimeDeviceSelector] = []
  var rumbleCalls: [RecordedRumble] = []
  var playerCalls: [(RuntimeDeviceSelector, PhysicalPlayerIndicator)] = []
  var colorCalls: [(RuntimeDeviceSelector, UInt8, UInt8, UInt8)] = []
  var colorReleaseCalls: [(RuntimeDeviceSelector, UUID)] = []
  var brightnessCalls: [(RuntimeDeviceSelector, UInt8)] = []
  var outputResult = true
  var outputThrows = false
  var activeOutputCalls = 0
  var maximumConcurrentOutputCalls = 0

  init(
    inputSequence: [DeviceInputState?] = [],
    inputDelayNanoseconds: UInt64 = 0,
    outputDelayNanoseconds: UInt64 = 0
  ) {
    self.inputSequence = inputSequence
    self.inputDelayNanoseconds = inputDelayNanoseconds
    self.outputDelayNanoseconds = outputDelayNanoseconds
  }

  func inputState(for selector: RuntimeDeviceSelector) async throws -> DeviceInputState? {
    inputCalls += 1
    activeInputCalls += 1
    maximumConcurrentInputCalls = max(maximumConcurrentInputCalls, activeInputCalls)
    inputSelectors.append(selector)
    defer { activeInputCalls -= 1 }
    if inputDelayNanoseconds > 0 {
      do { try await Task.sleep(nanoseconds: inputDelayNanoseconds) } catch {
        cancelledInputCalls += 1
        throw error
      }
    }
    guard !inputSequence.isEmpty else { return nil }
    return inputSequence.removeFirst()
  }

  func sendRumble(
    for selector: RuntimeDeviceSelector,
    left: UInt8,
    right: UInt8,
    leftTrigger: UInt8,
    rightTrigger: UInt8,
    durationMilliseconds: Int
  ) async throws -> Bool {
    try await beginOutputCall()
    defer { finishOutputCall() }
    if outputThrows { throw InputTestGatewayError.outputFailed }
    rumbleCalls.append(
      RecordedRumble(
        selector: selector,
        left: left,
        right: right,
        leftTrigger: leftTrigger,
        rightTrigger: rightTrigger,
        durationMilliseconds: durationMilliseconds
      )
    )
    return outputResult
  }

  func setPlayerIndicator(
    for selector: RuntimeDeviceSelector,
    indicator: PhysicalPlayerIndicator
  ) async throws -> Bool {
    try await beginOutputCall()
    defer { finishOutputCall() }
    playerCalls.append((selector, indicator))
    return outputResult
  }

  func previewColor(
    for selector: RuntimeDeviceSelector,
    token _: UUID,
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) async throws -> Bool {
    try await beginOutputCall()
    defer { finishOutputCall() }
    colorCalls.append((selector, red, green, blue))
    return outputResult
  }

  func releaseColorPreview(for selector: RuntimeDeviceSelector, token: UUID) async throws -> Bool {
    await Task.yield()
    colorReleaseCalls.append((selector, token))
    return outputResult
  }

  func setBrightness(for selector: RuntimeDeviceSelector, brightness: UInt8) async throws -> Bool {
    try await beginOutputCall()
    defer { finishOutputCall() }
    brightnessCalls.append((selector, brightness))
    return outputResult
  }

  func counts() -> (
    input: Int, cancelled: Int, maximumConcurrentInput: Int, maximumConcurrentOutput: Int,
    rumble: Int, player: Int, color: Int, brightness: Int
  ) {
    (
      inputCalls, cancelledInputCalls, maximumConcurrentInputCalls, maximumConcurrentOutputCalls,
      rumbleCalls.count, playerCalls.count, colorCalls.count, brightnessCalls.count
    )
  }

  func setOutputResult(_ result: Bool) { outputResult = result }
  func setOutputThrows(_ value: Bool) { outputThrows = value }

  func waitForInputCalls(_ expectedCount: Int) async -> Bool {
    for _ in 0..<500 {
      if inputCalls >= expectedCount { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return inputCalls >= expectedCount
  }

  func waitForRumbleCalls(_ expectedCount: Int) async -> Bool {
    for _ in 0..<500 {
      if rumbleCalls.count >= expectedCount { return true }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return rumbleCalls.count >= expectedCount
  }

  private func beginOutputCall() async throws {
    activeOutputCalls += 1
    maximumConcurrentOutputCalls = max(maximumConcurrentOutputCalls, activeOutputCalls)
    if outputDelayNanoseconds > 0 {
      do { try await Task.sleep(nanoseconds: outputDelayNanoseconds) } catch {
        // Callers install their cleanup defer only after this helper returns successfully.
        activeOutputCalls -= 1
        throw error
      }
    }
  }

  private func finishOutputCall() { activeOutputCalls -= 1 }
}

@Suite(.serialized)
struct InputTestTests {}
