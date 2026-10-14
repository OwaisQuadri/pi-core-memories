import Foundation
import Testing

@testable import CoreMemories

@Test func multilineCRLFIsOneLogicalLineEnding() {
  let lf = fact("Fact\ncontinued")
  let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
  #expect(MemoryDocument.failures(in: Data(lf.utf8)).isEmpty)
  #expect(MemoryDocument.failures(in: Data(crlf.utf8)).isEmpty)
  #expect(
    MemoryDocument.failures(
      in: Data("Fact\r\ncontinued [source: x; added: 2024-02-29]\r\n".utf8)
    ).isEmpty)
}

@Test func mixedLFAndCRLFKeepMultilineParagraphs() {
  let document =
    "# Memory\r\n\r\n" + fact("First\r\ncontinued\non another line") + "\r\n"
    + fact("Second\ncontinued").replacingOccurrences(of: "\n", with: "\r\n")
  #expect(MemoryDocument.failures(in: Data(document.utf8)).isEmpty)
}

@Test func crlfBlankLinesKeepParagraphBoundaries() {
  let valid = (fact("First\ncontinued") + "\n" + fact("Second\ncontinued") + "\n\n")
    .replacingOccurrences(of: "\n", with: "\r\n")
  #expect(MemoryDocument.failures(in: Data(valid.utf8)).isEmpty)
  let missing = (fact("First\ncontinued") + "\nMissing\nannotation\n")
    .replacingOccurrences(of: "\n", with: "\r\n")
  #expect(
    MemoryDocument.failures(in: Data(missing.utf8)) == [
      "line 4: missing or malformed [source: reference; added: YYYY-MM-DD]"
    ])
  let separated = "Missing\r\n\r\n" + fact("Annotated")
  #expect(
    MemoryDocument.failures(in: Data(separated.utf8)) == [
      "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"
    ])
}

@Test func crlfListItemsKeepSeparateAnnotationRequirements() {
  let valid = (fact("- First\n  continued") + fact("- Second\n  continued"))
    .replacingOccurrences(of: "\n", with: "\r\n")
  #expect(MemoryDocument.failures(in: Data(valid.utf8)).isEmpty)
  let missing =
    "- Missing\r\n  still missing\r\n"
    + fact("- Annotated\n  continued").replacingOccurrences(of: "\n", with: "\r\n")
  #expect(
    MemoryDocument.failures(in: Data(missing.utf8)) == [
      "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"
    ])
}

@Test func malformedMultilineCRLFStillFails() {
  for lf in [
    "Fact\ncontinued\n", "Fact\ncontinued [source: x]\n",
    "Fact\ncontinued [source: ; added: 2024-02-29]\n",
    fact("Fact\ncontinued").replacingOccurrences(of: "2024-02-29", with: "2024-02-30"),
  ] {
    let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
    let failures = MemoryDocument.failures(in: Data(crlf.utf8))
    #expect(!failures.isEmpty)
    #expect(failures == MemoryDocument.failures(in: Data(lf.utf8)))
  }
}

@Test func standaloneAndUnicodeNewlinesRemainSupported() {
  for ending in ["\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
    let document = fact("Fact\ncontinued").replacingOccurrences(of: "\n", with: ending)
    #expect(MemoryDocument.failures(in: Data(document.utf8)).isEmpty)
  }
}

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

@Test func executableCRLFProposalsPreserveBytesAndApprovedRendering() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let approved = fact("Executable approved\ncontinued").replacingOccurrences(
    of: "\n", with: "\r\n")
  try fixture.write(approved, path: "MEMORY.md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  let before = try fixture.humanState()
  let arguments = [
    "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
    "Synthetic executable CRLF candidate",
  ]
  let malformed = Data("Fact\r\ncontinued [source: x]\r\n".utf8)
  let rejected = try fixture.cli(arguments, input: malformed)
  #expect(rejected.status != 0 && rejected.output.isEmpty)
  #expect(rejected.errorText.contains("missing or malformed"))
  let replacement = Data(
    (fact("Executable pending\ncontinued 🐢").replacingOccurrences(of: "\n", with: "\r\n")
      + "\r\n\r\n").utf8)
  let proposed = try fixture.cli(arguments, input: replacement)
  try #require(proposed.status == 0 && proposed.error.isEmpty)
  let commitLine = try #require(
    proposed.text.split(separator: "\n").first(where: { $0.hasPrefix("commit: ") }))
  let commit = String(commitLine.dropFirst(8))
  let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
  #expect(try git.data(["cat-file", "blob", "\(commit):MEMORY.md"]) == replacement)
  let review = try fixture.cli(["review", "--repo", fixture.repo.path, commit])
  #expect(review.status == 0 && review.error.isEmpty)
  #expect(review.text == (try fixture.store.review(commit: commit)))
  #expect(review.text.contains("Executable pending\\u{D}\n"))
  #expect(!review.text.contains("\r"))
  #expect(review.text.contains("Parent/Base: \(base)"))
  let renderArguments = ["render", "--repo", fixture.repo.path, "--cwd", fixture.root.path]
  let rendered = try fixture.cli(renderArguments)
  #expect(rendered.status == 0 && rendered.error.isEmpty)
  #expect(rendered.output == Data(approved.utf8))
  #expect(try fixture.humanState() == before)
  _ = try fixture.git(["switch", "--detach", commit])
  try fixture.write("Unannotated executable human edit", path: "MEMORY.md")
  #expect(try fixture.cli(renderArguments).output == Data(approved.utf8))
  _ = try fixture.git(["update-ref", "refs/heads/main", commit, base])
  let approvedRender = try fixture.cli(renderArguments)
  #expect(approvedRender.status == 0 && approvedRender.error.isEmpty)
  #expect(approvedRender.output == replacement)
  let checked = try fixture.cli(["check", "--repo", fixture.repo.path])
  #expect(checked.status == 0 && checked.output.isEmpty && checked.error.isEmpty)
}
