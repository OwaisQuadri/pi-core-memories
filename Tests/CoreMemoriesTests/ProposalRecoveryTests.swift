import Foundation
import Testing

@testable import CoreMemories

@Test func exactProposalRecoverySurvivesHumanFastForward() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let replacement = Data((fact("Exact saved candidate 🐢") + "\n").utf8)
  let reason = "Saved reason\nwith Unicode 🐢"
  let contradictions = "Exact known conflict"
  let published = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
    contradictions: contradictions)
  let normal = try #require(
    try fixture.store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
      contradictions: contradictions))
  #expect(normal.ref == published.ref && normal.commit == published.commit && normal.base == base)
  _ = try fixture.git(["merge", "--ff-only", published.commit])
  #expect(try fixture.store.approvedCommit() == published.commit)
  try fixture.write("Staged human bytes", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Unstaged human bytes", path: "MEMORY.md")
  try fixture.write("Untracked human bytes", path: "human.txt")
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
      contradictions: contradictions)
  }
  let recovered = try #require(
    try fixture.store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
      contradictions: contradictions))
  #expect(recovered.ref == published.ref)
  #expect(recovered.commit == published.commit && recovered.base == base)
  #expect(
    try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/proposals/"])
      == published.ref)
  #expect(try fixture.snapshot(fixture.repo) == before)
}
