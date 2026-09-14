#if canImport(SwiftUI)

  import Combine
  import Foundation
  import OpenJoystickDriverKit

  protocol InputTestDeviceGateway: MotionCalibrationGateway {
    func inputState(for selector: RuntimeDeviceSelector) async throws -> DeviceInputState?
    func sendRumble(
      for selector: RuntimeDeviceSelector,
      left: UInt8,
      right: UInt8,
      leftTrigger: UInt8,
      rightTrigger: UInt8,
      durationMilliseconds: Int
    ) async throws -> Bool
    func setPlayerIndicator(
      for selector: RuntimeDeviceSelector,
      indicator: PhysicalPlayerIndicator
    ) async throws -> Bool
    func previewColor(
      for selector: RuntimeDeviceSelector,
      token: UUID,
      red: UInt8,
      green: UInt8,
      blue: UInt8
    ) async throws -> Bool
    func releaseColorPreview(for selector: RuntimeDeviceSelector, token: UUID) async throws -> Bool
    func setBrightness(for selector: RuntimeDeviceSelector, brightness: UInt8) async throws -> Bool
  }

  /// View-owned physical-output values are isolated from session state so continuous controls do
  /// not invalidate the live input hierarchy or window chrome while they are being dragged.
  @MainActor
  final class InputTestOutputSettings: ObservableObject {
    @Published
    var rumbleIntensities: [PhysicalRumbleMotor: Double] = [:]
    @Published
    var rumbleDurationMilliseconds = 300.0
    @Published
    var playerIndicator: PhysicalPlayerIndicator = .off
    @Published
    var red = 0.0
    @Published
    var green = 122.0
    @Published
    var blue = 255.0
    @Published
    var brightness = 255.0
  }

  @MainActor
  final class InputTestViewModel: ObservableObject {
    enum SessionState: Equatable {
      case idle
      case starting
      case live
      case stale
      case disconnected
      case permissionRequired
      case unavailable
      case error
    }

    enum OutputOperation: Equatable {
      case rumble
      case playerIndicator
      case color
      case brightness
    }

    enum OutputState: Equatable {
      case idle
      case running(OutputOperation)
      case succeeded(OutputOperation)
      case failed(OutputOperation)
    }

    typealias Sleep = @Sendable (UInt64) async throws -> Void

    @Published
    private(set) var device: ApplicationServiceDeviceDescription?
    @Published
    private(set) var sessionState: SessionState = .idle
    @Published
    private(set) var outputState: OutputState = .idle
    @Published
    private(set) var outputError: String?
    @Published
    private(set) var isDeviceConnected = false
    let liveState = InputTestLiveState()
    let outputSettings = InputTestOutputSettings()
    let motionCalibration: MotionCalibrationViewModel

    var rumbleIntensities: [PhysicalRumbleMotor: Double] {
      get { outputSettings.rumbleIntensities }
      set { outputSettings.rumbleIntensities = newValue }
    }

    var rumbleDurationMilliseconds: Double {
      get { outputSettings.rumbleDurationMilliseconds }
      set { outputSettings.rumbleDurationMilliseconds = newValue }
    }

    var playerIndicator: PhysicalPlayerIndicator {
      get { outputSettings.playerIndicator }
      set { outputSettings.playerIndicator = newValue }
    }

    var red: Double {
      get { outputSettings.red }
      set { outputSettings.red = newValue }
    }

    var green: Double {
      get { outputSettings.green }
      set { outputSettings.green = newValue }
    }

    var blue: Double {
      get { outputSettings.blue }
      set { outputSettings.blue = newValue }
    }

    var brightness: Double {
      get { outputSettings.brightness }
      set { outputSettings.brightness = newValue }
    }

    private let gateway: any InputTestDeviceGateway
    private let sampleIntervalNanoseconds: UInt64
    private let sleep: Sleep
    private let rumbleSleep: Sleep
    private var samplingTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var samplingGeneration: UInt64 = 0
    private var isWindowActive = false
    private var outputGeneration: UInt64 = 0
    private var outputSelector: RuntimeDeviceSelector?
    private var outputMayRequireRumbleStop = false
    private let colorPreviewToken = UUID()
    private var colorPreviewSelector: RuntimeDeviceSelector?

    init(
      gateway: any InputTestDeviceGateway,
      sampleIntervalNanoseconds: UInt64 = 33_333_333,
      sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) },
      rumbleSleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }
    ) {
      self.gateway = gateway
      motionCalibration = MotionCalibrationViewModel(gateway: gateway)
      self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
      self.sleep = sleep
      self.rumbleSleep = rumbleSleep
    }

    var capabilities: PhysicalControllerOutputCapabilities {
      device?.physicalOutputCapabilities ?? .none
    }

    var latestInput: DeviceInputState { liveState.snapshot }

    var isSampling: Bool { samplingTask != nil }

    var isOutputBusy: Bool {
      if case .running = outputState { return true }
      return false
    }

    var canSendOutput: Bool { isDeviceConnected && device != nil }
    var canStopRumble: Bool { outputMayRequireRumbleStop }

    func selectDevice(_ selectedDevice: ApplicationServiceDeviceDescription) {
      motionCalibration.select(RuntimeDeviceSelector(device: selectedDevice))
      guard device?.runtimeIdentifier != selectedDevice.runtimeIdentifier else {
        device = selectedDevice
        startSamplingIfNeeded()
        return
      }
      let oldSelector = device.map(RuntimeDeviceSelector.init(device:))
      cancelSampling(nextState: .idle)
      cancelOutput(stopSelector: oldSelector)
      device = selectedDevice
      isDeviceConnected = true
      liveState.reset(vendorID: selectedDevice.vendorID, productID: selectedDevice.productID)
      rumbleIntensities = Dictionary(
        uniqueKeysWithValues: selectedDevice.physicalOutputCapabilities.rumbleMotors.map {
          ($0, 0.0)
        }
      )
      sessionState = .idle
      outputState = .idle
      outputError = nil
      startSamplingIfNeeded()
    }

    func reconcileConnectedDevices(_ devices: [ApplicationServiceDeviceDescription]) {
      guard let current = device else { return }
      guard
        let refreshed = devices.first(where: { $0.runtimeIdentifier == current.runtimeIdentifier })
      else {
        isDeviceConnected = false
        motionCalibration.select(nil)
        cancelSampling(nextState: .disconnected)
        cancelOutput(stopSelector: RuntimeDeviceSelector(device: current))
        return
      }
      device = refreshed
      isDeviceConnected = true
      motionCalibration.select(RuntimeDeviceSelector(device: refreshed))
      if sessionState == .disconnected || sessionState == .permissionRequired {
        sessionState = .idle
      }
      startSamplingIfNeeded()
    }

    func reconcileStatus(_ status: RuntimeStatusPresentation) {
      reconcileConnectedDevices(status.devices)
      guard !isDeviceConnected, status.permissions.inputMonitoring != .granted,
        device?.discoverySource == .hid
      else { return }
      sessionState = .permissionRequired
    }

    func open() {
      isWindowActive = true
      startSamplingIfNeeded()
    }

    private func startSamplingIfNeeded() {
      guard isWindowActive, samplingTask == nil, isDeviceConnected else { return }
      guard let device else {
        sessionState = .disconnected
        return
      }
      samplingGeneration &+= 1
      let generation = samplingGeneration
      let selector = RuntimeDeviceSelector(device: device)
      sessionState = .starting
      samplingTask = Task { [weak self] in
        await self?.sampleLoop(selector: selector, generation: generation)
      }
    }

    func close() {
      isWindowActive = false
      cancelSampling(nextState: device == nil ? .disconnected : .idle)
      cancelOutput(stopSelector: device.map(RuntimeDeviceSelector.init(device:)))
      motionCalibration.select(nil)
    }

    func testRumble() {
      guard let device, canSendOutput, capabilities.supportsRumble else { return }
      let command = rumbleCommand()
      let selector = RuntimeDeviceSelector(device: device)
      let duration = max(100, min(2_000, Int(rumbleDurationMilliseconds.rounded())))
      beginOutputOperation(.rumble, selector: selector) { [gateway, rumbleSleep] in
        let sent = try await gateway.sendRumble(
          for: selector,
          left: command.left,
          right: command.right,
          leftTrigger: command.leftTrigger,
          rightTrigger: command.rightTrigger,
          durationMilliseconds: duration
        )
        guard sent else { return false }
        try await rumbleSleep(UInt64(duration) * 1_000_000)
        return true
      }
    }

    func stopRumble() {
      guard outputMayRequireRumbleStop, let device else { return }
      cancelOutput(stopSelector: RuntimeDeviceSelector(device: device))
    }

    func applyPlayerIndicator() {
      guard let device, canSendOutput, capabilities.supportsPlayerIndicator else { return }
      let selector = RuntimeDeviceSelector(device: device)
      let indicator = playerIndicator
      beginOutputOperation(.playerIndicator, selector: selector) { [gateway] in
        try await gateway.setPlayerIndicator(for: selector, indicator: indicator)
      }
    }

    func applyColor() {
      guard let device, canSendOutput, capabilities.lightingFeatures.contains(.programmableColor)
      else { return }
      let selector = RuntimeDeviceSelector(device: device)
      let components = (Self.byte(red), Self.byte(green), Self.byte(blue))
      let token = colorPreviewToken
      colorPreviewSelector = selector
      beginOutputOperation(.color, selector: selector) { [gateway] in
        try await gateway.previewColor(
          for: selector,
          token: token,
          red: components.0,
          green: components.1,
          blue: components.2
        )
      }
    }

    func applyBrightness() {
      guard let device, canSendOutput, capabilities.supportsProgrammableBrightness else { return }
      let selector = RuntimeDeviceSelector(device: device)
      let value = Self.byte(brightness)
      beginOutputOperation(.brightness, selector: selector) { [gateway] in
        try await gateway.setBrightness(for: selector, brightness: value)
      }
    }

    private func sampleLoop(selector: RuntimeDeviceSelector, generation: UInt64) async {
      var receivedSnapshot = false
      var consecutiveFailures = 0
      while !Task.isCancelled, generation == samplingGeneration {
        do {
          let snapshot = try await gateway.inputState(for: selector)
          try Task.checkCancellation()
          guard generation == samplingGeneration else { return }
          if let snapshot {
            liveState.update(snapshot)
            if sessionState != .live { sessionState = .live }
            receivedSnapshot = true
            consecutiveFailures = 0
          } else {
            consecutiveFailures += 1
            sessionState = receivedSnapshot ? .stale : .starting
          }
        } catch is CancellationError { return } catch {
          guard generation == samplingGeneration else { return }
          consecutiveFailures += 1
          sessionState = receivedSnapshot ? .stale : .starting
        }

        if consecutiveFailures >= 3 {
          sessionState = receivedSnapshot ? .stale : .unavailable
          samplingTask = nil
          return
        }

        do { try await sleep(sampleIntervalNanoseconds) } catch { return }
      }
    }

    private func cancelSampling(nextState: SessionState) {
      samplingGeneration &+= 1
      samplingTask?.cancel()
      samplingTask = nil
      sessionState = nextState
    }

    private func beginOutputOperation(
      _ operation: OutputOperation,
      selector: RuntimeDeviceSelector,
      body: @escaping @Sendable () async throws -> Bool
    ) {
      outputGeneration &+= 1
      let previousTask = outputTask
      let previousSelector = outputSelector
      let shouldStopPreviousRumble = outputMayRequireRumbleStop
      previousTask?.cancel()
      let generation = outputGeneration
      let gateway = self.gateway
      outputSelector = selector
      outputMayRequireRumbleStop = operation == .rumble
      outputState = .running(operation)
      outputError = nil
      outputTask = Task { [weak self] in
        do {
          await previousTask?.value
          if shouldStopPreviousRumble, let previousSelector {
            _ = try? await gateway.sendRumble(
              for: previousSelector,
              left: 0,
              right: 0,
              leftTrigger: 0,
              rightTrigger: 0,
              durationMilliseconds: 0
            )
          }
          try Task.checkCancellation()
          let succeeded = try await body()
          try Task.checkCancellation()
          guard let self, generation == self.outputGeneration else { return }
          self.clearOutputOperation()
          self.outputState = succeeded ? .succeeded(operation) : .failed(operation)
          if !succeeded {
            self.outputError = OJDLocalized.string(
              "inputTest.outputRejected",
              fallback: "The controller rejected this output test."
            )
          }
        } catch is CancellationError {
          guard let self, generation == self.outputGeneration else { return }
          self.clearOutputOperation()
          self.outputState = .idle
          self.outputError = nil
        } catch {
          guard let self, generation == self.outputGeneration else { return }
          self.clearOutputOperation()
          self.outputState = .failed(operation)
          self.outputError = RuntimePresentation.userFacingError(error)
        }
      }
    }

    private func clearOutputOperation() {
      outputTask = nil
      outputSelector = nil
      outputMayRequireRumbleStop = false
    }

    private func cancelOutput(stopSelector selector: RuntimeDeviceSelector?) {
      outputGeneration &+= 1
      let previousTask = outputTask
      let activeSelector = outputSelector ?? selector
      let shouldStopRumble = outputMayRequireRumbleStop
      let previewSelector = colorPreviewSelector
      colorPreviewSelector = nil
      let colorPreviewToken = colorPreviewToken
      previousTask?.cancel()
      outputSelector = nil
      outputMayRequireRumbleStop = false
      outputState = .idle
      outputError = nil
      outputTask = Task { [gateway] in
        await previousTask?.value
        if shouldStopRumble, let activeSelector {
          _ = try? await gateway.sendRumble(
            for: activeSelector,
            left: 0,
            right: 0,
            leftTrigger: 0,
            rightTrigger: 0,
            durationMilliseconds: 0
          )
        }
        if let previewSelector {
          _ = try? await gateway.releaseColorPreview(for: previewSelector, token: colorPreviewToken)
        }
      }
    }

    private func rumbleCommand() -> (
      left: UInt8, right: UInt8, leftTrigger: UInt8, rightTrigger: UInt8
    ) {
      var left: UInt8 = 0
      var right: UInt8 = 0
      var leftTrigger: UInt8 = 0
      var rightTrigger: UInt8 = 0
      let binary = Set(capabilities.binaryRumbleMotors)
      for motor in capabilities.rumbleMotors {
        let raw = rumbleIntensities[motor] ?? 0
        let value: UInt8 = binary.contains(motor) ? (raw > 0 ? 255 : 0) : Self.byte(raw)
        switch motor {
        case .leftMain, .leftHaptic: left = max(left, value)
        case .rightMain, .rightHaptic: right = max(right, value)
        case .leftTrigger: leftTrigger = value
        case .rightTrigger: rightTrigger = value
        }
      }
      return (left, right, leftTrigger, rightTrigger)
    }

    private static func byte(_ value: Double) -> UInt8 {
      UInt8(clamping: Int(max(0, min(255, value)).rounded()))
    }
  }

#endif
