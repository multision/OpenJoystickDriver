import Testing

@testable import OpenJoystickDriver

struct CommandCatalogTests {
  @Test
  func catalogPathsAreUnique() {
    let commands = InstalledCommandCatalog.commands
    let paths = commands.map(\.path)

    #expect(Set(paths).count == paths.count)
  }

  @Test
  func catalogUsesStableLogicalOrder() {
    let groups = InstalledCommandCatalog.commands.map(\.group)
    let order = ["Overview", "Controllers", "Configuration", "System", "Support"]

    #expect(
      groups
        == groups.sorted { left, right in
          guard let leftIndex = order.firstIndex(of: left),
            let rightIndex = order.firstIndex(of: right)
          else { return false }
          return leftIndex < rightIndex
        }
    )
    #expect(InstalledCommandCatalog.commands.first?.path == "status [--json]")
  }

}
