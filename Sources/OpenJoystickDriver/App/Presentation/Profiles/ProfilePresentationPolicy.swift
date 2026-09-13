#if os(macOS)
  import CoreGraphics
  import Foundation
  import OpenJoystickDriverKit

  enum ProfileEditorSection: String, CaseIterable, Identifiable {
    case assignments
    case combinations
    case layers
    case controller

    var id: Self { self }

    var title: String {
      switch self {
      case .assignments: return OJDLocalized.string("common.assignments", fallback: "Assignments")
      case .combinations:
        return OJDLocalized.string("profiles.combinations", fallback: "Combinations")
      case .layers: return OJDLocalized.string("profiles.layers", fallback: "Layers")
      case .controller: return OJDLocalized.string("common.controller", fallback: "Controller")
      }
    }
  }

  enum ProfileEditorNavigationStyle: Equatable {
    case segmented
    case popUp
  }

  enum ProfileAssignmentRowLayout: Equatable {
    case inline
    case stacked
  }

  enum ProfilePresentationPolicy {
    static let sectionOrder = ProfileEditorSection.allCases
    static let defaultSection = ProfileEditorSection.assignments
    static let compactNavigationWidth: CGFloat = 620
    static let inlineAssignmentWidth: CGFloat = 680

    static func navigationStyle(for width: CGFloat) -> ProfileEditorNavigationStyle {
      width < compactNavigationWidth ? .popUp : .segmented
    }

    static func assignmentRowLayout(for width: CGFloat) -> ProfileAssignmentRowLayout {
      width < inlineAssignmentWidth ? .stacked : .inline
    }
  }
#endif
