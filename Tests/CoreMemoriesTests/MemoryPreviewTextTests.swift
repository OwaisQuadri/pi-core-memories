import Foundation
import Testing

@testable import CoreMemories

@Test func previewTextOmitsStorageAnnotationsWithoutChangingEntryBytes() throws {
  let entry = Data(
    ("Use IEEE for research papers. [source: synthetic; added: 2026-11-07] "
      + "[memory-id: 11111111-1111-4111-8111-111111111111; reviewed: 2026-11-07T00:00:00Z]\n").utf8)
  let original = entry
  #expect(try MemoryDocument.displayText(entry) == "Use IEEE for research papers.")
  #expect(entry == original)
  #expect(try MemoryDocument.displayText(Data()).isEmpty)
}

@Test(arguments: ["**synthetic**", "*synthetic*", "`synthetic`"])
func previewTextOmitsFormattedSourceReferences(_ reference: String) throws {
  let entry = Data("Keep this. [source: \(reference); added: 2026-11-07]\n".utf8)
  let original = entry
  #expect(MemoryDocument.failures(in: entry).isEmpty)
  #expect(try MemoryDocument.displayText(entry) == "Keep this.")
  #expect(entry == original)
}

@Test func previewTextRetainsLiteralCodeAndOrdinaryBrackets() throws {
  let entry = Data(
    "Keep `[source: literal; added: 2026-11-07]` and [ordinary text]. [source: synthetic; added: 2026-11-07]\n"
      .utf8)
  #expect(
    try MemoryDocument.displayText(entry)
      == "Keep `[source: literal; added: 2026-11-07]` and [ordinary text].")
}

@Test func previewScopeResolvesAutomaticProjectAndWorktreeNames() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let project = try fixture.project("Research")
  let unrelated = try fixture.project("Other")
  let worktree = fixture.root.appendingPathComponent("task-checkout")
  _ = try fixture.git(["worktree", "add", "-b", "task", worktree.path], at: project)
  let key = try #require(try MemoryStore.projectKey(cwd: project))
  let device = String(repeating: "a", count: 64)
  var configuration = MemoryConfiguration.defaults
  configuration.deviceKey = device
  func description(_ path: String, directories: [String]) throws -> MemoryChangeDescription {
    try MemoryChangeDescription(
      before: Data(), after: Data("Keep this.".utf8), path: path, configuration: configuration,
      projectDirectories: directories)
  }
  #expect(
    try description("projects/\(key).md", directories: [project.path, worktree.path]).scope
      == "for the Research project")
  #expect(
    try description("devices/\(device)/projects/\(key).md", directories: [worktree.path]).scope
      == "for the Research project on this device")
  #expect(throws: MemoryChangeDescriptionError.unidentifiedProject) {
    try description("projects/\(key).md", directories: [unrelated.path])
  }
  configuration.projectBindings = [
    try #require(try MemoryStore.projectBindingDirectory(cwd: project)): key
  ]
  #expect(
    try description("projects/\(key).md", directories: []).scope == "for the Research project")
}

@Test func previewScopeDoesNotNameSeparateGitMetadataAsTheProject() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("Research")
  let metadata = fixture.root.appendingPathComponent("metadata")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try fixture.git(["init", "--template=", "--separate-git-dir=\(metadata.path)"], at: project)
  _ = try fixture.git(["commit", "--allow-empty", "-m", "Separate directory fixture"], at: project)
  let key = try #require(try MemoryStore.projectKey(cwd: project))
  var configuration = MemoryConfiguration.defaults
  func description() throws -> MemoryChangeDescription {
    try MemoryChangeDescription(
      before: Data(), after: Data("Keep this.".utf8), path: "projects/\(key).md",
      configuration: configuration, projectDirectories: [project.path])
  }
  let scope = try description().scope
  #expect(scope == "for the Research project")
  configuration.projectBindings = [
    try #require(try MemoryStore.projectBindingDirectory(cwd: project)): key
  ]
  #expect(try description().scope == "for the metadata project")
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
  #expect(
    try description("devices/\(device)/projects/\(project).md").scope
      == "for the Research project on this device")
  #expect(throws: (any Error).self) {
    try description("devices/\(String(repeating: "c", count: 64))/MEMORY.md")
  }
  configuration.projectBindings = [:]
  #expect(throws: (any Error).self) { try description("projects/\(project).md") }
}
