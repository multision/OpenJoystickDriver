#if canImport(AppKit) && canImport(SwiftUI)

  import AppKit
  import OpenJoystickDriverKit
  import SwiftUI

  extension InputTestLiveInputView {
    @ViewBuilder
    var body: some View {
      if embedded {
        content
      } else {
        GroupBox {
          content
        } label: {
          Text(OJDLocalized.string("inputTest.controls", fallback: "Live input")).font(.headline)
        }
      }
    }

    var content: some View {
      let snapshot = liveState.snapshot
      let pressedButtons = Set(snapshot.pressedButtons)
      let presentation = publishedProfile.presentation
      let symbols = InputTestControllerSymbolSet.resolve(for: presentation.glyphFamily)
      return VStack(spacing: 10) {
        shoulderRow(snapshot: snapshot, pressedButtons: pressedButtons, symbols: symbols)
        Divider()
        HStack(alignment: .center, spacing: 18) {
          dpadCluster(pressedButtons: pressedButtons).frame(maxWidth: .infinity)
          systemCluster(
            pressedButtons: pressedButtons,
            symbols: symbols,
            publishedProfile: publishedProfile
          ).frame(maxWidth: .infinity)
          faceButtonCluster(pressedButtons: pressedButtons, symbols: symbols).frame(
            maxWidth: .infinity
          )
        }
        Divider()
        HStack(alignment: .top, spacing: 24) {
          InputTestStickView(
            title: OJDLocalized.string("inputTest.leftStick", fallback: "Left stick"),
            x: snapshot.leftStickX,
            y: snapshot.leftStickY,
            clickPresentation: symbols.leftStickClick,
            clickActive: isPressed([.leftStick], in: pressedButtons)
          )
          InputTestStickView(
            title: OJDLocalized.string("inputTest.rightStick", fallback: "Right stick"),
            x: snapshot.rightStickX,
            y: snapshot.rightStickY,
            clickPresentation: symbols.rightStickClick,
            clickActive: isPressed([.rightStick], in: pressedButtons)
          )
        }
        let additionalButtons = InputTestButtonPresentation.additionalButtons(in: snapshot)
        if !additionalButtons.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            Text(OJDLocalized.string("inputTest.additionalButtons", fallback: "Additional buttons"))
              .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
              ForEach(additionalButtons, id: \.self) { rawName in
                InputTestIndicator(
                  title: InputTestButtonPresentation.localizedTitle(for: rawName),
                  active: true
                )
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }.padding(6)
    }

    private func shoulderRow(
      snapshot: DeviceInputState,
      pressedButtons: Set<String>,
      symbols: InputTestControllerSymbolSet
    ) -> some View {
      HStack(spacing: 10) {
        indicator(
          symbols.leftShoulder,
          buttons: [.leftBumper, .l1],
          pressedButtons: pressedButtons
        )
        indicator(
          symbols.leftTrigger,
          active: snapshot.leftTrigger > 0.05 || isPressed([.l2Digital], in: pressedButtons)
        )
        indicator(
          symbols.rightTrigger,
          active: snapshot.rightTrigger > 0.05 || isPressed([.r2Digital], in: pressedButtons)
        )
        indicator(
          symbols.rightShoulder,
          buttons: [.rightBumper, .r1],
          pressedButtons: pressedButtons
        )
      }
    }

    private func dpadCluster(pressedButtons: Set<String>) -> some View {
      VStack(spacing: 6) {
        indicator(
          OJDLocalized.string("inputTest.dpadUp", fallback: "D-pad up"),
          symbol: "dpad.up.filled",
          fallbackSymbol: "arrowtriangle.up.fill",
          buttons: [.dpadUp],
          pressedButtons: pressedButtons
        )
        HStack(spacing: 6) {
          indicator(
            OJDLocalized.string("inputTest.dpadLeft", fallback: "D-pad left"),
            symbol: "dpad.left.filled",
            fallbackSymbol: "arrowtriangle.left.fill",
            buttons: [.dpadLeft],
            pressedButtons: pressedButtons
          )
          indicator(
            OJDLocalized.string("inputTest.dpadRight", fallback: "D-pad right"),
            symbol: "dpad.right.filled",
            fallbackSymbol: "arrowtriangle.right.fill",
            buttons: [.dpadRight],
            pressedButtons: pressedButtons
          )
        }
        indicator(
          OJDLocalized.string("inputTest.dpadDown", fallback: "D-pad down"),
          symbol: "dpad.down.filled",
          fallbackSymbol: "arrowtriangle.down.fill",
          buttons: [.dpadDown],
          pressedButtons: pressedButtons
        )
      }
    }

    @ViewBuilder
    private func systemCluster(
      pressedButtons: Set<String>,
      symbols: InputTestControllerSymbolSet,
      publishedProfile: VirtualDeviceProfile
    ) -> some View {
      let glyphFamily = publishedProfile.presentation.glyphFamily
      switch InputTestSystemClusterLayout.resolve(for: publishedProfile) {
      case .standard:
        HStack(spacing: 6) {
          indicator(
            symbols.view,
            buttons: InputTestSystemClusterLayout.viewButtons(for: glyphFamily),
            pressedButtons: pressedButtons
          )
          indicator(symbols.guide, active: isPressed([.guide, .ps], in: pressedButtons))
          indicator(symbols.menu, buttons: [.start, .options], pressedButtons: pressedButtons)
        }
      case .xboxWithShare:
        VStack(spacing: 6) {
          HStack(spacing: 6) {
            indicator(symbols.view, buttons: [.back], pressedButtons: pressedButtons)
            indicator(symbols.guide, active: isPressed([.guide], in: pressedButtons))
            indicator(symbols.menu, buttons: [.start], pressedButtons: pressedButtons)
          }
          HStack(spacing: 6) {
            systemPlaceholder
            indicator(
              InputTestSystemClusterLayout.shareControl,
              buttons: InputTestSystemClusterLayout.shareButtons,
              pressedButtons: pressedButtons
            )
            systemPlaceholder
          }
        }
      }
    }

    private var systemPlaceholder: some View { Color.clear.frame(width: 54, height: 30) }

    private func faceButtonCluster(
      pressedButtons: Set<String>,
      symbols: InputTestControllerSymbolSet
    ) -> some View {
      VStack(spacing: 6) {
        indicator(symbols.northFace, buttons: [.y, .triangle], pressedButtons: pressedButtons)
        HStack(spacing: 6) {
          indicator(symbols.westFace, buttons: [.x, .square], pressedButtons: pressedButtons)
          indicator(symbols.eastFace, buttons: [.b, .circle], pressedButtons: pressedButtons)
        }
        indicator(symbols.southFace, buttons: [.a, .cross], pressedButtons: pressedButtons)
      }
    }

    private func indicator(
      _ presentation: InputTestControllerSymbolSet.Control,
      buttons: [OpenJoystickDriverKit.Button],
      pressedButtons: Set<String>
    ) -> some View { indicator(presentation, active: isPressed(buttons, in: pressedButtons)) }

    func indicator(
      _ title: String,
      symbol: String,
      fallbackSymbol: String? = nil,
      buttons: [OpenJoystickDriverKit.Button],
      pressedButtons: Set<String>
    ) -> some View {
      InputTestIndicator(
        title: title,
        symbol: symbol,
        fallbackSymbol: fallbackSymbol,
        active: isPressed(buttons, in: pressedButtons)
      )
    }

    func indicator(_ presentation: InputTestControllerSymbolSet.Control, active: Bool) -> some View
    {
      InputTestIndicator(
        title: presentation.title,
        symbol: presentation.symbol,
        fallbackSymbol: presentation.fallbackSymbol,
        fallbackText: presentation.fallbackText,
        active: active
      )
    }

    private func isPressed(
      _ buttons: [OpenJoystickDriverKit.Button],
      in pressedButtons: Set<String>
    ) -> Bool { InputTestButtonPresentation.isPressed(buttons, in: pressedButtons) }

  }

#endif
