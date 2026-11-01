import Foundation
import Testing

@testable import CoreMemories

@Test func ordinaryRepositoriesRejectCoreAndExecutableProposals() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  for isWithMemoryDocument in [false, true] {
    let project = try fixture.project(isWithMemoryDocument ? "source-with-memory" : "source")
    try fixture.write("# Ordinary project\n", path: "README.md", at: project)
    if isWithMemoryDocument {
      try fixture.write("# Memory\n", path: "MEMORY.md", at: project)
    }
    _ = try fixture.git(["add", "."], at: project)
    _ = try fixture.git(["commit", "-m", "Ordinary project fixture"], at: project)
    let base = try fixture.git(["rev-parse", "refs/heads/main"], at: project)
    let before = try fixture.snapshot(project)
    let replacement = Data(fact("Candidate must stay out of source repositories").utf8)
    let store = try MemoryStore(repo: project)
    #expect(throws: (any Error).self) {
      _ = try store.propose(
        base: base, path: "MEMORY.md", replacement: replacement, reason: "Boundary check")
    }
    #expect(try fixture.snapshot(project) == before)
    let result = try fixture.cli(
      [
        "propose", "--repo", project.path, "--base", base, "--file", "MEMORY.md",
        "--reason", "Boundary check",
      ], input: replacement)
    #expect(result.status != 0 && result.output.isEmpty)
    #expect(result.errorText.hasPrefix("FAIL "))
    #expect(try fixture.snapshot(project) == before)
  }
}
