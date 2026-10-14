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

@Test func aMemoryLayoutCanProposeRepairingInvalidAnnotations() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write("An existing fact has no citation.\n", path: "MEMORY.md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  let before = try fixture.humanState()
  let proposal = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: Data(fact("A corrected fact").utf8),
    reason: "Add a citation for human review")
  #expect(try fixture.humanState() == before)
  #expect(try fixture.store.review(commit: proposal.commit).contains("A corrected fact"))
  #expect(try fixture.store.approvedCommit() == base)
}
