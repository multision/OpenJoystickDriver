import AppKit
import OpenJoystickDriverKit
import Testing

@testable import OpenJoystickDriver

struct InputTestPresentationTests {
  @Test
  func inputTestWindowUsesTheRequestedStableSizing() {
    #expect(InputTestWindowSizingPolicy.defaultContentSize == NSSize(width: 900, height: 620))
    #expect(InputTestWindowSizingPolicy.minimumContentSize == NSSize(width: 700, height: 500))
    #expect(
      InputTestWindowSizingPolicy.fittingContentSize(NSSize(width: 640, height: 420))
        == InputTestWindowSizingPolicy.minimumContentSize
    )
  }

  @Test
  func layoutContainsEverySectionAndCompactsAtNarrowWidths() {
    #expect(InputTestLayoutPolicy.sectionOrder == [.liveInput, .axes, .motion, .rumble, .lighting])
    #expect(InputTestLayoutPolicy.widthClass(for: 700) == .compact)
    #expect(InputTestLayoutPolicy.widthClass(for: 860) == .regular)
    #expect(InputTestLayoutPolicy.widthClass(for: 1_200) == .wide)
  }

  @Test
  func canonicalButtonsDriveTheStandardInputMap() {
    var state = DeviceInputState(vendorID: 1, productID: 2)
    state.pressedButtons = [
      Button.leftBumper.rawValue, Button.dpadUp.rawValue, Button.leftStick.rawValue,
      Button.l2Digital.rawValue, Button.leftFunction.rawValue, Button.rightFunction.rawValue,
      Button.leftPaddle.rawValue, Button.rightPaddle.rawValue, Button.leftSL.rawValue,
      Button.leftSR.rawValue, Button.rightSL.rawValue, Button.rightSR.rawValue,
      Button.mute.rawValue,
    ]

    #expect(InputTestButtonPresentation.isPressed([.leftBumper, .l1], in: state))
    #expect(InputTestButtonPresentation.isPressed([.dpadUp], in: state))
    #expect(InputTestButtonPresentation.isPressed([.leftStick], in: state))
    #expect(InputTestButtonPresentation.isPressed([.l2Digital], in: state))
    #expect(
      InputTestButtonPresentation.additionalButtons(in: state) == [
        "leftFunction", "leftPaddle", "leftSL", "leftSR", "mute", "rightFunction", "rightPaddle",
        "rightSL", "rightSR",
      ]
    )
  }

  @Test
  func controllerFamiliesSelectProtocolAppropriateInputSymbols() {
    let xbox = InputTestControllerSymbolSet.resolve(for: .xbox)
    #expect(xbox.leftShoulder.symbol == "lb.button.roundedbottom.horizontal")
    #expect(xbox.leftTrigger.symbol == "lt.button.roundedtop.horizontal")
    #expect(xbox.guide.symbol == "xbox.logo")
    #expect(xbox.leftStickClick.symbol == "lsb.button.angledbottom.horizontal.left")

    let playStation = InputTestControllerSymbolSet.resolve(for: .playstation)
    #expect(playStation.leftShoulder.symbol == "l1.button.roundedbottom.horizontal")
    #expect(playStation.leftTrigger.symbol == "l2.button.roundedtop.horizontal")
    #expect(playStation.guide.symbol == "playstation.logo")
    #expect(playStation.southFace.symbol == "xmark.circle")

    let switchController = InputTestControllerSymbolSet.resolve(for: .nintendo)
    #expect(switchController.leftTrigger.symbol == "zl.button.roundedtop.horizontal")
    #expect(switchController.view.symbol == "minus.circle")
    #expect(switchController.menu.symbol == "plus.circle")

    let generic = InputTestControllerSymbolSet.resolve(for: .generic)
    #expect(generic.leftShoulder.symbol == nil)
    #expect(generic.leftShoulder.fallbackText == "LB / L1")
    #expect(generic.guide.symbol == "house.fill")
  }

  @Test
  func systemControlLayoutFollowsControllerFamily() {
    let xbox = InputTestSystemClusterLayout.resolve(for: .xboxSeries)
    #expect(xbox == .xboxWithShare)
    #expect(xbox.rows == [[.view, .guide, .menu], [.empty, .share, .empty]])
    #expect(InputTestSystemClusterLayout.viewButtons(for: .xbox) == [.back])
    #expect(InputTestSystemClusterLayout.shareButtons == [.share])

    let playStation = InputTestSystemClusterLayout.resolve(for: .dualSenseUSB)
    #expect(playStation == .standard)
    #expect(playStation.rows == [[.view, .guide, .menu]])
    #expect(InputTestSystemClusterLayout.viewButtons(for: .playstation) == [.share])
  }
}
