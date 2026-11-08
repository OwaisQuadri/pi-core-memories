import Foundation
import Testing

@testable import CoreMemories

@Test func previewTextOmitsStorageAnnotationsWithoutChangingEntryBytes() throws {
  let entry = Data((
    "Use IEEE for research papers. [source: synthetic; added: 2026-11-07] "
      + "[memory-id: 11111111-1111-4111-8111-111111111111; reviewed: 2026-11-07T00:00:00Z]\n").utf8)
  let original = entry
  #expect(try MemoryDocument.displayText(entry) == "Use IEEE for research papers.")
  #expect(entry == original)
  #expect(try MemoryDocument.displayText(Data()).isEmpty)
}

@Test func previewTextRetainsLiteralCodeAndOrdinaryBrackets() throws {
  let entry = Data("Keep `[source: literal; added: 2026-11-07]` and [ordinary text]. [source: synthetic; added: 2026-11-07]\n".utf8)
  #expect(try MemoryDocument.displayText(entry) == "Keep `[source: literal; added: 2026-11-07]` and [ordinary text].")
}

@Test func previewScopeUsesNamesAndRejectsUnidentifiedTargets() throws {
  let device = String(repeating: "a", count: 64)
  let project = String(repeating: "b", count: 64)
  var configuration = MemoryConfiguration.defaults
  configuration.deviceKey = device
  configuration.projectBindings = ["/synthetic/Research": project]
  func description(_ path: String) throws -> MemoryChangeDescription {
    try MemoryChangeDescription(
      before: Data(), after: Data("Use IEEE.".utf8), path: path, configuration: configuration)
  }
  #expect(try description("MEMORY.md").scope.isEmpty)
  #expect(try description("projects/\(project).md").scope == "for the Research project")
  #expect(try description("devices/\(device)/MEMORY.md").scope == "on this device")
  #expect(try description("devices/\(device)/projects/\(project).md").scope == "for the Research project on this device")
  #expect(throws: (any Error).self) { try description("devices/\(String(repeating: "c", count: 64))/MEMORY.md") }
  configuration.projectBindings = [:]
  #expect(throws: (any Error).self) { try description("projects/\(project).md") }
}
