import Foundation

extension DevicePipeline {
  enum USBOpenResult {
    case opened(any USBTransportSession)
    case unavailable(USBTransportError)
  }

  // MARK: - Private USB pipeline

  func startUSBPipeline(device: USBTransportDevice) async {
    guard let provider = usbTransportProvider else {
      print("[DevicePipeline] Missing USB transport provider for \(identifier)")
      isActive = false
      return
    }

    var openAttempt: Int = 0
    while isActive {
      let openResult = await openDeviceWithRetry(provider: provider, device: device)
      guard case .opened(let handle) = openResult else {
        guard isActive else { return }
        let ownership: HIDInputOwnership
        if case .unavailable(.accessDenied) = openResult {
          ownership = .accessDenied
        } else {
          ownership = .acquisitionFailed
        }
        await reportUSBInputOwnership(ownership)
        guard isActive else { return }
        openAttempt += 1
        let delay: UInt64
        if case .unavailable(.accessDenied) = openResult {
          if openAttempt == 1 {
            print(
              "[DevicePipeline] USB device is exclusively owned by another process; waiting:"
                + " \(identifier)"
            )
          }
          delay = usbRecoveryPolicy.accessContentionDelayNanoseconds
        } else {
          print("[DevicePipeline] USB device unavailable; retrying: \(identifier)")
          delay = usbRecoveryPolicy.reconnectDelayNanoseconds(after: openAttempt)
        }
        try? await Task.sleep(nanoseconds: delay)
        continue
      }
      guard isActive else {
        await handle.close()
        return
      }
      usbHandle = handle
      consecutiveUSBIOErrors = 0
      (parser as? any InputParserSessionLifecycle)?.resetProtocolState()

      guard await performUSBHandshake(handle: handle) else {
        // Try again while active, but slow down to avoid hot loops that launchd may kill
        // as "inefficient".
        openAttempt += 1
        let delay = usbRecoveryPolicy.reconnectDelayNanoseconds(after: openAttempt)
        try? await Task.sleep(nanoseconds: delay)
        continue
      }

      guard isActive else {
        await handle.close()
        usbHandle = nil
        return
      }

      let ownership = await handle.inputOwnership
      guard isActive else { return }
      await reportUSBInputOwnership(ownership)
      guard isActive else { return }
      openAttempt = 0
      if !requiresInputConnectionBeforeOutput() {
        await dispatcher.dispatch(events: [], from: identifier)
      }

      await runUSBInputLoop(handle: handle)

      if !isActive { return }

      // Prevent immediate reopen loops.
      openAttempt += 1
      let delay = usbRecoveryPolicy.reconnectDelayNanoseconds(after: openAttempt)
      try? await Task.sleep(nanoseconds: delay)
    }
  }

  func reportUSBInputOwnership(_ ownership: HIDInputOwnership) async {
    if let listener = dispatcher as? any ControllerInputOwnershipListener {
      await listener.controllerInputOwnershipChanged(ownership, for: identifier)
    }
  }

  func performUSBHandshake(handle: any USBTransportSession) async -> Bool {
    let retryDelays = (parser as? any USBStartupOutputProvider)?.usbStartupRetryDelays ?? []
    for attempt in 0...retryDelays.count {
      do {
        try await sendUSBStartupOutputPackets(handle: handle)
        startupOutputStatus = "succeeded"
        print("[DevicePipeline] Handshake complete:" + " \(identifier)")
        return true
      } catch {
        startupOutputStatus = "failed: \(error)"
        print(
          "[DevicePipeline] Handshake attempt \(attempt + 1) failed for \(identifier): \(error)"
        )
        guard attempt < retryDelays.count else { break }
        do { try await Task.sleep(nanoseconds: retryDelays[attempt]) } catch { break }
      }
    }
    usbHandle = nil
    await handle.close()
    return false
  }

  func sendUSBStartupOutputPackets(handle: any USBTransportSession) async throws {
    guard let startupOutput = parser as? USBStartupOutputProvider else { return }
    let packets = startupOutput.usbStartupOutputPackets()
    for (index, packet) in packets.enumerated() {
      do {
        _ = try await handle.writeInterruptPacket(
          endpoint: transportProfile.outputEndpoint,
          data: packet,
          timeout: 2000
        )
        appendToPacketLog(bytes: packet, direction: "tx")
      } catch let error as USBTransportError
        where isIgnorableUSBStartupOutputError(parser: parser, packet: packet, error: error)
      {
        print(
          "[DevicePipeline] Optional USB startup output rejected for \(identifier):" + " \(error)"
        )
      }
      if index < packets.count - 1, startupOutput.usbStartupOutputIntervalNanoseconds > 0 {
        try await Task.sleep(nanoseconds: startupOutput.usbStartupOutputIntervalNanoseconds)
      }
    }
  }

  func openDeviceWithRetry(
    provider: any USBTransportProvider,
    device: USBTransportDevice
  ) async -> USBOpenResult {
    var lastError = USBTransportError.notFound
    for attempt in 0..<usbRecoveryPolicy.openRetryDelays.count {
      do {
        return .opened(
          try await provider.open(
            device,
            options: USBTransportOpenOptions(transportProfile: transportProfile)
          )
        )
      } catch let error as USBTransportError {
        lastError = error
        if error == .accessDenied { return .unavailable(error) }
        handleOpenDeviceError(error, attempt: attempt)
        if attempt < usbRecoveryPolicy.openRetryDelays.count - 1 {
          try? await Task.sleep(nanoseconds: usbRecoveryPolicy.openRetryDelays[attempt])
        }
      } catch {
        let transportError = USBTransportError.platform(code: 0, message: String(describing: error))
        lastError = transportError
        handleOpenDeviceError(transportError, attempt: attempt)
        if attempt < usbRecoveryPolicy.openRetryDelays.count - 1 {
          try? await Task.sleep(nanoseconds: usbRecoveryPolicy.openRetryDelays[attempt])
        }
      }
    }
    return .unavailable(lastError)
  }

  func handleOpenDeviceError(_ error: Error, attempt: Int) {
    print("[DevicePipeline] Open attempt \(attempt + 1) failed" + " for \(identifier): \(error)")
  }

  func runUSBInputLoop(handle: any USBTransportSession) async {
    let inEndpoint = transportProfile.inputEndpoint
    var lastKeepAliveNs = DispatchTime.now().uptimeNanoseconds
    print(
      "[DevicePipeline] Starting USB input loop:" + " \(identifier)"
        + " inEP=0x\(String(inEndpoint, radix: 16))"
    )

    if transportProfile.postHandshakeSettleNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: transportProfile.postHandshakeSettleNanoseconds)
    }

    while isActive {
      let loopStartNs = DispatchTime.now().uptimeNanoseconds
      if shouldSendKeepAlive(lastKeepAliveNs: lastKeepAliveNs, now: loopStartNs) {
        lastKeepAliveNs = loopStartNs
        await runKeepAlive(handle: handle)
      }
      var shouldBreak = false
      var shouldThrottleIdle = false
      do {
        let bytes = try await readInterrupt(handle: handle, inEndpoint: inEndpoint)
        consecutiveUSBIOErrors = 0
        appendToPacketLog(bytes: bytes, direction: "rx")
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let events = try parseEvents(from: bytes, receivedAtNanoseconds: receivedAt)
        await sendDeferredUSBOutputPackets(handle: handle)
        _ = await handleInputConnectionStateChangeIfNeeded()
        if inputConnectionActive { await handleParsedEvents(events, now: receivedAt) }
      } catch let error as USBTransportError where error.isTimeout {
        // No data in this interval; throttle below to avoid a hot timeout loop.
        shouldThrottleIdle = true
      } catch let error as USBTransportError where error.isDisconnected {
        print("[DevicePipeline] Device disconnected:" + " \(identifier)")
        await invalidateUSBHandle(handle)
        shouldBreak = true
      } catch let error as USBTransportError where error.isInputOutput {
        consecutiveUSBIOErrors += 1

        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastUSBIOErrorLogNs >= usbIOErrorLogIntervalNs {
          lastUSBIOErrorLogNs = now
          print(
            "[DevicePipeline] USB I/O error (will recover)" + " for \(identifier): \(error)"
              + " (consecutive=\(consecutiveUSBIOErrors))"
          )
        }

        // Back off to avoid a launchd "inefficient" kill.
        let exp = min(max(0, consecutiveUSBIOErrors - 1), 4)
        let backoff = min(usbIOErrorBackoffMaxNs, usbIOErrorBackoffBaseNs << exp)
        try? await Task.sleep(nanoseconds: backoff)

        if consecutiveUSBIOErrors >= usbIOErrorReconnectThreshold {
          print("[DevicePipeline] Too many USB I/O errors. Reconnecting:" + " \(identifier)")
          await invalidateUSBHandle(handle)
          shouldBreak = true
        }
      } catch {
        // Slow down after an unknown failure, then reconnect.
        print("[DevicePipeline] Read error" + " for \(identifier):" + " \(error). Reconnecting")
        await invalidateUSBHandle(handle)
        shouldBreak = true
      }

      if shouldBreak { break }

      // Throttle idle timeouts only. Successful packets should dispatch at device cadence.
      let loopElapsedNs = DispatchTime.now().uptimeNanoseconds &- loopStartNs
      if shouldThrottleIdle && loopElapsedNs < usbIdleLoopCadenceNs {
        try? await Task.sleep(nanoseconds: usbIdleLoopCadenceNs &- loopElapsedNs)
      } else {
        await Task.yield()
      }
    }

    await invalidateUSBHandle(handle)
    await reportUSBInputOwnership(.unknown)
    await neutralizeOutput()
    print("[DevicePipeline] Input loop ended:" + " \(identifier)")
  }

  func shouldSendKeepAlive(lastKeepAliveNs: UInt64, now: UInt64) -> Bool {
    guard let provider = parser as? any USBKeepAliveOutputProvider else { return false }
    return now &- lastKeepAliveNs >= provider.usbKeepAliveIntervalNanoseconds
  }

  func runKeepAlive(handle: any USBTransportSession) async {
    guard let packet = (parser as? any USBKeepAliveOutputProvider)?.usbKeepAlivePacket() else {
      return
    }
    do {
      _ = try await handle.writeInterruptPacket(
        endpoint: packet.endpoint,
        data: packet.bytes,
        timeout: packet.timeoutMilliseconds
      )
    } catch { print("[DevicePipeline] Keep-alive failed" + " for \(identifier): \(error)") }
  }

  func readInterrupt(handle: any USBTransportSession, inEndpoint: UInt8) async throws -> [UInt8] {
    try await handle.readInterruptPacket(
      endpoint: inEndpoint,
      length: gipReadPacketLength,
      timeout: gipReadTimeoutMs
    )
  }

  func parseEvents(
    from bytes: [UInt8],
    receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) throws -> [ControllerEvent] {
    let events = try parser.parse(data: Data(bytes), receivedAtNanoseconds: receivedAtNanoseconds)
    snapshotBatteryTelemetry()
    return events
  }

  func sendDeferredUSBOutputPackets(handle: any USBTransportSession) async {
    guard let output = parser as? any USBDeferredOutputProvider else { return }
    for packet in output.consumeUSBOutputPackets() {
      do {
        _ = try await handle.writeInterruptPacket(
          endpoint: transportProfile.outputEndpoint,
          data: packet,
          timeout: 2_000
        )
        appendToPacketLog(bytes: packet, direction: "tx")
      } catch {
        print("[DevicePipeline] Deferred USB output failed for \(identifier): \(error)")
        break
      }
    }
  }

  func startIdleMonitor() {
    idleMonitorTask?.cancel()
    idleMonitorTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: idleMonitorIntervalNanoseconds)
        await self.evaluateIdleSleep()
      }
    }
  }

  func evaluateIdleSleep() async {
    guard isActive else { return }
    if let liveness = parser as? any ControllerInputReportLivenessProvider,
      let last = lastLiveInputReportNanoseconds ?? inputHealthMonitoringStartedNanoseconds,
      DispatchTime.now().uptimeNanoseconds - last >= liveness.inputReportLivenessTimeoutNanoseconds
    {
      await retireOutputAfterLivenessLoss()
    }
  }
}
