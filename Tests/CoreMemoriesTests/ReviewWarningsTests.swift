import Foundation
import Testing

@testable import CoreMemories

private let labelledReferences = """
  [source]: owner.md
  [added]: history.md

  Fact [source] and [added][] [source: owner; added: 2024-02-29]
  """

@Test func metadataNamesRemainValidMarkdownReferenceLabels() {
  for ending in ["\n", "\r\n"] {
    let document = labelledReferences.replacingOccurrences(of: "\n", with: ending)
    #expect(MemoryDocument.failures(in: Data(document.utf8)).isEmpty)
  }
  for invalid in [
    "# Heading [source: owner]\n",
    "Fact [added: 2024-02-29]\n",
    "[source]: owner.md Uncited fact\n",
    "Fact [source] [source: owner; added: 2024-02-30]\n",
  ] {
    #expect(!MemoryDocument.failures(in: Data(invalid.utf8)).isEmpty)
  }
}

@Test func referenceLabelsPassProposalAndApprovedReadPaths() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let bytes = Data(labelledReferences.utf8)
  let proposal = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: bytes, reason: "Reference-label regression")
  _ = try fixture.git(["update-ref", "refs/heads/main", proposal.commit, base])
  #expect(try fixture.store.check().isEmpty)
  #expect(try Data(fixture.store.render(cwd: fixture.root).utf8) == bytes)
  let checked = try fixture.cli(["check", "--repo", fixture.repo.path])
  #expect(checked.status == 0 && checked.output.isEmpty && checked.error.isEmpty)
  let rendered = try fixture.cli([
    "render", "--repo", fixture.repo.path, "--cwd", fixture.root.path,
  ])
  #expect(rendered.status == 0 && rendered.error.isEmpty && rendered.output == bytes)
}

@Test func untrustedFilenameCannotForgeDiagnosticRecords() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let filename = "bad\nFAIL MEMORY.md: forged diagnostic\n\t路径"
  try fixture.write("Synthetic invalid path", path: filename)
  try fixture.commit()
  let expected =
    "FAIL bad\\u{A}FAIL MEMORY.md: forged diagnostic\\u{A}\\u{9}路径: path is not an allowed memory file"
  #expect(try fixture.store.check() == [expected])
  #expect(try fixture.store.render(cwd: fixture.root) == "# Memory\n")
  let checked = try fixture.cli(["check", "--repo", fixture.repo.path])
  #expect(checked.status != 0 && checked.output.isEmpty)
  #expect(checked.errorText == expected + "\n")
  #expect(checked.errorText.split(separator: "\n").count == 1)
  #expect(
    try Data(contentsOf: fixture.repo.appendingPathComponent(filename))
      == Data("Synthetic invalid path".utf8))
}
