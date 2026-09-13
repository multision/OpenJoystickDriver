import Testing

@testable import OpenJoystickDriver

struct ProfilePresentationTests {
  @Test
  func focusedEditorContainsEverySectionInTaskOrder() {
    #expect(
      ProfilePresentationPolicy.sectionOrder == [.assignments, .combinations, .layers, .controller]
    )
    #expect(ProfilePresentationPolicy.defaultSection == .assignments)
  }

  @Test
  func sectionNavigationUsesAvailableEditorWidth() {
    #expect(ProfilePresentationPolicy.navigationStyle(for: 619) == .popUp)
    #expect(ProfilePresentationPolicy.navigationStyle(for: 620) == .segmented)
  }

  @Test
  func assignmentRowsStackOnlyBelowTheirReadableWidth() {
    #expect(ProfilePresentationPolicy.assignmentRowLayout(for: 679) == .stacked)
    #expect(ProfilePresentationPolicy.assignmentRowLayout(for: 680) == .inline)
  }
}
