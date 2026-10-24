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

@Test(arguments: [false, true])
func symbolicProposalRefsAreRefused(isWithExistingTarget: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let replacement = Data(fact("Alias candidate").utf8)
  let proposal = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: "Alias check")
  _ = try fixture.git(["update-ref", "--no-deref", "-d", proposal.ref])
  let target = "refs/heads/human"
  if isWithExistingTarget {
    _ = try fixture.git(["update-ref", target, proposal.commit])
  }
  _ = try fixture.git(["symbolic-ref", proposal.ref, target])
  try fixture.write("Staged human memory", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Unstaged human memory", path: "MEMORY.md")
  try fixture.write("Untracked human bytes", path: "human.txt")
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "Alias check")
  }
  #expect(try fixture.snapshot(fixture.repo) == before)
  let result = try fixture.cli(
    [
      "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md",
      "--reason", "Alias check",
    ], input: replacement)
  #expect(result.status != 0 && result.output.isEmpty)
  #expect(try fixture.git(["symbolic-ref", proposal.ref]) == target)
  #expect(try fixture.snapshot(fixture.repo) == before)
}

@Test(arguments: [false, true])
func symbolicMainCannotPublishOrDeduplicate(isDuplicate: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let replacement = Data(fact("Main alias candidate").utf8)
  let proposal = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: "Main alias check")
  if !isDuplicate {
    _ = try fixture.git(["update-ref", "--no-deref", "-d", proposal.ref])
  }
  _ = try fixture.git(["update-ref", "refs/heads/human", base])
  _ = try fixture.git(["update-ref", "--no-deref", "-d", "refs/heads/main"])
  _ = try fixture.git(["symbolic-ref", "refs/heads/main", "refs/heads/human"])
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "Main alias check")
  }
  #expect(try fixture.snapshot(fixture.repo) == before)
  let result = try fixture.cli(
    [
      "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md",
      "--reason", "Main alias check",
    ], input: replacement)
  #expect(result.status != 0 && result.output.isEmpty)
  #expect(try fixture.snapshot(fixture.repo) == before)
}

@Test func acceptedEmptyDirectoryBecomesPrivate() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let repo = root.appendingPathComponent("existing755")
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path)
  #expect(try permissions(repo) == 0o755)
  try MemoryStore.initialize(repo: repo)
  #expect(try permissions(repo) == 0o700)
  #expect(try permissions(repo.appendingPathComponent("MEMORY.md")) == 0o600)
  #expect(try MemoryStore(repo: repo).render(cwd: root) == "# Memory\n")
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

@Test func rejectedDestinationsKeepHumanBytesAndModes() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let occupied = fixture.root.appendingPathComponent("occupied755")
  try fixture.write("Human data", path: "keep", at: occupied)
  let keep = occupied.appendingPathComponent("keep")
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: occupied.path)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keep.path)
  let before = try fixture.snapshot(occupied)
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: occupied) }
  #expect(try fixture.snapshot(occupied) == before)
  #expect(try permissions(occupied) == 0o755)
  #expect(try permissions(keep) == 0o644)
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: keep) }
  #expect(try permissions(keep) == 0o644)
  #expect(try Data(contentsOf: keep) == Data("Human data".utf8))

  let empty = fixture.root.appendingPathComponent("empty-target755")
  try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: empty.path)
  let link = fixture.root.appendingPathComponent("symlink")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
  let linkMode = try permissions(link)
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: link) }
  #expect(try permissions(link) == linkMode)
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == empty.path)
  #expect(try permissions(empty) == 0o755)
  #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
  let absent = fixture.root.appendingPathComponent("absent")
  let dangling = fixture.root.appendingPathComponent("dangling")
  try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: absent)
  let danglingMode = try permissions(dangling)
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: dangling) }
  #expect(try permissions(dangling) == danglingMode)
  #expect(!FileManager.default.fileExists(atPath: absent.path))

  let nested = fixture.repo.appendingPathComponent("nested755")
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
  let repositoryBefore = try fixture.snapshot(fixture.repo)
  let rootMode = try permissions(fixture.repo)
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: nested) }
  #expect(try permissions(nested) == 0o755)
  #expect(try permissions(fixture.repo) == rootMode)
  #expect(try fixture.snapshot(fixture.repo) == repositoryBefore)
  let missingNested = fixture.repo.appendingPathComponent("missing-nested")
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: missingNested) }
  #expect(!FileManager.default.fileExists(atPath: missingNested.path))
  #expect(try fixture.snapshot(fixture.repo) == repositoryBefore)
}

@Test func repeatedSecurityOperationsPreserveHumanState() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let before = try fixture.humanState()
  let binary = try #require(
    ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_BIN"]
      ?? ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_EXECUTABLE"])
  let body = String(repeating: fact("Repeated review café 👩🏽‍💻 🐢"), count: 128)
  var createSeconds = 0.0
  var duplicateSeconds = 0.0
  var reviewSeconds = 0.0
  for repetition in 0...5 {
    let replacement = Data((body + fact("Candidate \(repetition)")).utf8)
    let arguments = [
      "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md",
      "--reason", "Repeated security operation",
    ]
    let createStart = Date.timeIntervalSinceReferenceDate
    let created = try fixture.cli(arguments, input: replacement)
    let createElapsed = Date.timeIntervalSinceReferenceDate - createStart
    try #require(created.status == 0)
    let commitLine = try #require(
      created.text.split(separator: "\n").first { $0.hasPrefix("commit: ") })
    let commit = String(commitLine.dropFirst(8))
    let duplicateStart = Date.timeIntervalSinceReferenceDate
    let duplicate = try fixture.cli(arguments, input: replacement)
    let duplicateElapsed = Date.timeIntervalSinceReferenceDate - duplicateStart
    #expect(duplicate.status == 0 && duplicate.output == created.output)
    let reviewStart = Date.timeIntervalSinceReferenceDate
    let review = try fixture.cli(["review", "--repo", fixture.repo.path, commit])
    let reviewElapsed = Date.timeIntervalSinceReferenceDate - reviewStart
    #expect(review.status == 0 && review.text.contains(fact("Repeated review café 👩🏽‍💻 🐢")))
    if repetition > 0 {
      createSeconds += createElapsed
      duplicateSeconds += duplicateElapsed
      reviewSeconds += reviewElapsed
    }
  }
  #expect(try fixture.humanState() == before)
  print(
    "SECURITY_TIMING binary=\(binary) bytes=\(body.utf8.count) warmup=1 repetitions=5 "
      + "create_ms=\(createSeconds * 200) duplicate_ms=\(duplicateSeconds * 200) "
      + "review_ms=\(reviewSeconds * 200)")
}
