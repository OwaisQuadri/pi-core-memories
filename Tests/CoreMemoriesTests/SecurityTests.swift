import Foundation
import Testing

@testable import CoreMemories

private struct StoredReviewMetadata: Decodable {
  let reason: String
  let contradictions: String
}

private func permissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777
}

@Test func humanReviewEscapesControlsWithoutChangingStoredBytes() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let controls =
    Array(0...8) + Array(11...31) + Array(127...159)
    + [0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x206F)
  let rawControls = controls.map { String(Unicode.Scalar($0)!) }.joined()
  let printable = "café العربية 👩🏽‍💻 🐢\tstill here\n"
  let reason = "Reason \u{1B}[2J\u{1B}[HAPPROVED\n" + printable + rawControls
  let contradictions = "Conflict \u{1B}[2J\u{1B}[HAPPROVED\n" + printable + rawControls
  let body = fact("Body \u{1B}[8mHIDDEN\u{1B}[0m " + printable.dropLast())
  let headings = controls.filter { $0 != 0 }.map {
    "# Before\(Unicode.Scalar($0)!)# After\n"
  }.joined()
  let original = Data(body.utf8)
  try fixture.write(String(decoding: original, as: UTF8.self), path: "MEMORY.md")
  try fixture.commit()
  #expect(Data(try fixture.store.render(cwd: fixture.root).utf8) == original)
  let replacement = Data(("New " + body + headings + fact("New fact")).utf8)
  let proposal = try fixture.store.propose(
    base: fixture.store.approvedCommit(), path: "MEMORY.md", replacement: replacement,
    reason: reason, contradictions: contradictions)
  let review = try fixture.store.review(commit: proposal.commit)
  let isSafe = !review.unicodeScalars.contains { controls.contains(Int($0.value)) }
  #expect(isSafe)
  let isVisible = controls.allSatisfy {
    review.contains("\\u{\(String($0, radix: 16, uppercase: true))}")
  }
  #expect(isVisible)
  let isBodyVisible = review.contains("-Body \\u{1B}[8mHIDDEN\\u{1B}[0m")
  #expect(isBodyVisible)
  let isReasonVisible = review.contains("Reason:\nReason \\u{1B}[2J\\u{1B}[HAPPROVED")
  #expect(isReasonVisible)
  let isContradictionsVisible = review.contains(
    "Contradictions:\nConflict \\u{1B}[2J\\u{1B}[HAPPROVED")
  #expect(isContradictionsVisible)
  #expect(review.contains(printable))
  let result = try fixture.cli(["review", "--repo", fixture.repo.path, proposal.commit])
  #expect(result.status == 0 && result.error.isEmpty)
  #expect(result.output == Data(review.utf8))
  let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
  #expect(try git.data(["cat-file", "blob", "\(proposal.commit):MEMORY.md"]) == replacement)
  let commit = try fixture.git(["cat-file", "commit", proposal.commit])
  let prefix = try #require(commit.range(of: "\n\nCore memory proposal\n\n"))
  let metadata = try JSONDecoder().decode(
    StoredReviewMetadata.self, from: Data(commit[prefix.upperBound...].utf8))
  #expect(metadata.reason == reason)
  #expect(metadata.contradictions == contradictions)
  #expect(Data(try fixture.store.render(cwd: fixture.root).utf8) == original)
}

@Test func newDirectoryAndMemoryArePrivateWithPermissiveUmask() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let repo = root.appendingPathComponent("new000")
  let binary = try #require(
    ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_BIN"]
      ?? ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_EXECUTABLE"])
  let result = try runCommand(
    executable: URL(fileURLWithPath: "/bin/zsh"),
    arguments: [
      "-lc", "umask 000; exec \"$1\" init --repo \"$2\"", "security-init", binary, repo.path,
    ],
    environment: ProcessInfo.processInfo.environment)
  #expect(result.status == 0 && result.output.isEmpty && result.error.isEmpty)
  #expect(try permissions(repo) == 0o700)
  #expect(try permissions(repo.appendingPathComponent("MEMORY.md")) == 0o600)
  #expect(try MemoryStore(repo: repo).render(cwd: root) == "# Memory\n")
}
