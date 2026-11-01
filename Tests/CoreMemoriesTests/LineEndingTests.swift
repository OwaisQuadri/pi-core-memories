import Foundation
import Testing

@testable import CoreMemories

@Test func coreCRLFProposalsPreserveBytesAndApprovedRendering() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let approved = fact("Approved\ncontinued").replacingOccurrences(of: "\n", with: "\r\n")
  try fixture.write(approved, path: "MEMORY.md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  let before = try fixture.humanState()
  let replacement = Data(
    (fact("Pending\ncontinued 🐢").replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n").utf8)
  let proposal = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: "Synthetic CRLF candidate")
  let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
  #expect(try git.data(["cat-file", "blob", "\(proposal.commit):MEMORY.md"]) == replacement)
  let review = try fixture.store.review(commit: proposal.commit)
  let diff = try git.data([
    "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--binary", base,
    proposal.commit, "--",
  ])
  let displayDiff = String(decoding: diff, as: UTF8.self).replacingOccurrences(
    of: "\r", with: "\\u{D}")
  #expect(review.contains(displayDiff))
  #expect(review.contains("Pending\\u{D}\n"))
  #expect(!review.contains("\r"))
  #expect(review.contains("Parent/Base: \(base)"))
  #expect(try Data(fixture.store.render(cwd: fixture.root).utf8) == Data(approved.utf8))
  #expect(try fixture.store.check().isEmpty)
  #expect(try fixture.humanState() == before)
  _ = try fixture.git(["switch", "--detach", proposal.commit])
  try fixture.write("Unannotated human edit", path: "MEMORY.md")
  #expect(try Data(fixture.store.render(cwd: fixture.root).utf8) == Data(approved.utf8))
  _ = try fixture.git(["update-ref", "refs/heads/main", proposal.commit, base])
  #expect(try Data(fixture.store.render(cwd: fixture.root).utf8) == replacement)
  #expect(try fixture.store.check().isEmpty)
}
