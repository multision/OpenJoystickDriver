import Foundation

extension DevicePipeline {

  func handleParsedEvents(_ events: [ControllerEvent], now: UInt64) async {
    guard sessionState == .active else { return }
    let observation = (parser as? any ControllerInputReportObserver)?.latestInputReportObservation
    if observation != nil { lastObservedInputReportNanoseconds = now }
    if let liveness = parser as? any ControllerInputReportLivenessProvider {
      if let last = lastLiveInputReportNanoseconds ?? inputHealthMonitoringStartedNanoseconds,
        now - last >= liveness.inputReportLivenessTimeoutNanoseconds
      {
        await retireOutputAfterLivenessLoss()
      }
      if observation?.isFresh == true { lastLiveInputReportNanoseconds = now }
      if awaitingNeutralAfterLivenessLoss {
        guard let observation, observation.isFresh else { return }
        var observedState = DeviceInputState(
          vendorID: identifier.vendorID,
          productID: identifier.productID
        )
        observedState.apply(events: observation.controls)
        guard observedState.isEffectivelyNeutral else { return }
        resetObservedInputState()
        outputState = currentInputState
        awaitingNeutralAfterLivenessLoss = false
        inputHealthRecoveryCount += 1
        await dispatcher.dispatch(events: [], from: identifier)
        return
      }
    }
    let previousState = currentInputState
    let sourceEvents: [ControllerEvent]
    if let observation {
      var observedState = DeviceInputState(
        vendorID: identifier.vendorID,
        productID: identifier.productID
      )
      observedState.apply(events: observation.controls)
      let samples = events.filter { event in
        switch event {
        case .motionSample, .touchSample: return true
        default: return false
        }
      }
      sourceEvents = previousState.transitionEvents(to: observedState) + samples
      currentInputState = observedState
    } else {
      sourceEvents = events
    }
    let normalizedEvents = ControllerEventNormalizer.normalize(sourceEvents, from: previousState)
      .events
    let nextState = previousState.applying(events: normalizedEvents)
    if observation == nil { updateObservedInputState(from: normalizedEvents) }

    if !externalOutputAllowed { return }
    if waitingForExternalNeutral {
      if nextState.isEffectivelyNeutral {
        waitingForExternalNeutral = false
        print("[DevicePipeline] Foreground gate re-armed after neutral: \(identifier)")
        return
      }
      if !normalizedEvents.isEmpty {
        waitingForExternalNeutral = false
        print(
          "[DevicePipeline] Foreground gate re-armed after first post-focus change: \(identifier)"
        )
      }
      return
    }
    if !normalizedEvents.isEmpty {
      await dispatcher.dispatch(events: normalizedEvents, from: identifier)
    }
    updateOutputState(from: normalizedEvents)
  }
}
