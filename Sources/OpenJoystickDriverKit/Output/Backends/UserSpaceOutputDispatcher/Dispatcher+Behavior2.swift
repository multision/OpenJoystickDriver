import CoreHID
import Darwin
import Foundation
import IOKit
import IOKit.hid
import Security

extension UserSpaceOutputDispatcher {

  internal func deliver(
    events: [ControllerEvent],
    from identifier: DeviceIdentifier,
    remappedState: RemappingGamepadState?,
    motionUpdate: RemappingVirtualMotionState??
  ) async throws {
    let neutralizing = remappedState == .neutral || motionUpdate == .some(nil)
    let remapped = remappedState != nil || motionUpdate != nil
    let outputSuppressed = isOutputSuppressed(remapped: remapped)
    guard lifecycle.isOpen, !outputSuppressed || neutralizing || !remapped else {
      throw CancellationError()
    }
    let activeEntry: Entry
    do {
      if neutralizing {
        guard let existing = registryLock.withLock({ entries[identifier] }) else { return }
        activeEntry = existing
      } else {
        activeEntry = try await entry(for: identifier)
      }
    } catch {
      registryLock.withLock { if lifecycle.isOpen { _status = "error: \(error)" } }
      throw error
    }
    guard lifecycle.isOpen else { throw CancellationError() }
    if outputSuppressed && !neutralizing { return }
    let stickTransfer =
      remappedState == nil
      ? Self.stickTransfer(for: identifier) : StickTransfer(deadzone: 0, rescalesDeadzone: false)
    let isActive: @Sendable () -> Bool = { [self] in
      lifecycle.isOpen && (!isOutputSuppressed(remapped: remapped) || neutralizing)
    }
    do {
      try await activeEntry.sender.submit(whileActive: isActive, requireActive: true) {
        [self, activeEntry] in
        guard isActive() else { throw CancellationError() }
        let primaryReport: [UInt8]?
        if let motionUpdate {
          guard motionUpdate == nil || activeEntry.inputReportState.supportsMotion else {
            throw RemappingEventEngineError.sinkUnavailable
          }
          primaryReport = activeEntry.inputReportState.updateMotion(motionUpdate)
        } else {
          primaryReport = activeEntry.inputReportState.update(remapped: remapped) { state in
            if let remappedState {
              let motion = state.motion
              let motionSamples = state.motionSamples
              let motionTimestamp = state.motionTimestampNanoseconds
              state = VirtualGamepadState()
              state.motion = motion
              state.motionSamples = motionSamples
              state.motionTimestampNanoseconds = motionTimestamp
              for event in remappedState.events(since: .neutral) {
                applyEvent(event, stickTransfer: stickTransfer, state: &state)
              }
            } else {
              for event in events { applyEvent(event, stickTransfer: stickTransfer, state: &state) }
            }
          }
        }
        var reports = primaryReport.map { [$0] } ?? []
        if emitsXboxGuideReport {
          if let remappedState {
            reports.append([0x02, remappedState.buttons.contains(.guide) ? 0x01 : 0x00])
          } else {
            reports += events.compactMap { xboxGuideReport(for: $0) }
          }
        }
        return reports
      }.value()
      startInputReportKeepalive(activeEntry)
      registryLock.withLock { recomputeStatusLocked() }
    } catch {
      let removed = registryLock.withLock { () -> Entry? in
        guard entries[identifier] === activeEntry else { return nil }
        _status = "error: \(error)"
        return entries.removeValue(forKey: identifier)
      }
      await removed?.close()
      throw error
    }
  }

  internal func entry(for identifier: DeviceIdentifier) async throws -> Entry {
    let result: (task: Task<Entry, Error>, generation: UInt64) = try registryLock.withLock {
      guard lifecycle.isOpen else { throw CancellationError() }
      let generation = lifecycleGenerations[identifier, default: 0]
      if let entry = entries[identifier] { return (Task { entry }, generation) }
      if let task = creationTasks[identifier] { return (task, generation) }

      let now = DispatchTime.now().uptimeNanoseconds
      let retryPolicy = creationRetryPolicies[identifier] ?? UserSpaceDeviceCreationRetryPolicy()
      guard retryPolicy.permitsAttempt(at: now) else { throw CreationError.createFailed }

      let task = Task { try await self.createEntry(for: identifier) }
      creationTasks[identifier] = task
      return (task, generation)
    }
    let (task, generation) = result

    do {
      let entry = try await task.value
      let installed = registryLock.withLock { () -> Bool in
        guard lifecycle.isOpen, lifecycleGenerations[identifier, default: 0] == generation else {
          return false
        }
        creationTasks.removeValue(forKey: identifier)
        creationRetryPolicies.removeValue(forKey: identifier)
        entries[identifier] = entry
        recomputeStatusLocked()
        return true
      }
      guard installed else {
        await entry.close()
        throw CancellationError()
      }
      return entry
    } catch {
      registryLock.withLock {
        guard lifecycleGenerations[identifier, default: 0] == generation else { return }
        creationTasks.removeValue(forKey: identifier)
        var policy = creationRetryPolicies[identifier] ?? UserSpaceDeviceCreationRetryPolicy()
        policy.recordFailure(at: DispatchTime.now().uptimeNanoseconds)
        creationRetryPolicies[identifier] = policy
      }
      throw error
    }
  }

  internal func recomputeStatusLocked() {
    _status = entries.isEmpty ? "off" : "on (devices=\(entries.count))"
  }
}
