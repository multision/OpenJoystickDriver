import Testing

@testable import OpenJoystickDriverKit

extension GyroRoutingTests {
  @Test
  func gyroStickUsesAngularSpeedAndNeutralizesAtSampleTimeout() {
    var engine = RemappingEngineState()
    let device = DeviceIdentifier(vendorID: 1, productID: 2)
    let profile = RemappingProfile(
      name: "Gyro stick",
      device: RemappingDeviceScope(vendorID: 1, productID: 2),
      applicationScope: .global,
      outputPolicy: RemappingOutputPolicy(virtualGamepad: .mapped),
      motionTuning: RemappingMotionTuning(space: .local, automaticBias: false),
      gyroOutput: RemappingGyroOutput(mode: .rightStick, fullStickDegreesPerSecond: 100),
      bindings: []
    )
    _ = engine.process(
      events: [.motionSample(sample(0, time: 0))],
      from: device,
      profile: profile,
      at: 0
    )
    let movement = engine.process(
      events: [.motionSample(sample(1, time: 10_000_000))],
      from: device,
      profile: profile,
      at: 10_000_000
    )
    #expect(
      movement == [
        .gamepad(RemappingGamepadState(axes: [.rightStickX: -1, .rightStickY: 0.5]), device)
      ]
    )
    #expect(
      engine.nextScheduledTick(after: 10_000_000, continuousIntervalNanoseconds: 8_000_000)
        == 110_000_000
    )
    let before = engine.tick(at: 109_999_999)
    #expect(before.isEmpty)
    let expired = engine.tick(at: 110_000_000)
    #expect(expired == [.gamepad(.neutral, device)])
    #expect(!engine.hasScheduledOutput)
  }

  @Test
  func mouseUsesSampleTimeAndDoesNotReplayBaselineOrDuplicateSamples() {
    var engine = RemappingEngineState()
    let device = DeviceIdentifier(vendorID: 1, productID: 2)
    let profile = RemappingProfile(
      name: "Gyro mouse",
      device: RemappingDeviceScope(vendorID: 1, productID: 2),
      applicationScope: .global,
      motionTuning: RemappingMotionTuning(space: .local, automaticBias: false),
      gyroOutput: RemappingGyroOutput(mode: .mouse, pointerPointsPerDegree: 2),
      bindings: []
    )
    let baseline = engine.process(
      events: [.motionSample(sample(0, time: 0))],
      from: device,
      profile: profile,
      at: 0
    )
    #expect(baseline.isEmpty)
    let movement = engine.process(
      events: [.motionSample(sample(1, time: 10_000_000))],
      from: device,
      profile: profile,
      at: 10_000_000
    )
    #expect(movement == [.system(.pointerDelta(x: -2, y: -1))])
    let duplicate = engine.process(
      events: [.motionSample(sample(1, time: 10_000_000))],
      from: device,
      profile: profile,
      at: 10_000_000
    )
    #expect(duplicate.isEmpty)
    let gap = engine.process(
      events: [.motionSample(sample(2, time: 500_000_000))],
      from: device,
      profile: profile,
      at: 500_000_000
    )
    #expect(gap.isEmpty)
    #expect(engine.tick(at: 510_000_000).isEmpty)
  }

  func sample(_ index: UInt64, time: UInt64) -> ControllerMotionSample {
    ControllerMotionSample(
      timestamp: ControllerSampleTimestamp(

        rawCounter: 0,
        elapsedNanoseconds: time,
        tickNanosecondsNumerator: nil,
        tickNanosecondsDenominator: nil,
        sequenceIndex: index,
        basis: .hostEstimate
      ),
      rawGyroscope: ControllerRawSensorVector(x: 0, y: 0, z: 0),
      rawAccelerometer: ControllerRawSensorVector(x: 0, y: 0, z: 0),
      physicalReading: ControllerMotionReading(
        gyroscopeDegreesPerSecond: ControllerMotionVector(x: 50, y: 100, z: 0),
        accelerationG: ControllerMotionVector(x: 0, y: 1, z: 0),

        calibrationSource: .nominalDeviceScale
      )
    )
  }
}
