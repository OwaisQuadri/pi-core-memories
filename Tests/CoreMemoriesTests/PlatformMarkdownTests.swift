import Foundation
import Testing

@testable import CoreMemories

private let observedBypasses = [
  (
    "Cited paragraph [source: owner; added: 2024-02-29]\n> Uncited paragraph\n",
    "line 2: missing or malformed [source: reference; added: YYYY-MM-DD]"
  ),
  (
    "[rule]: docs/owner.md Uncited fact\n",
    "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"
  ),
]

@Test func platformParagraphBoundariesRejectObservedBypasses() throws {
  let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: true)
  for (document, diagnostic) in observedBypasses {
    let parsed = try AttributedString(markdown: document, options: options)
    let identities = Set(
      parsed.runs.compactMap { run -> Int? in
        guard let intent = run.presentationIntent?.components.first,
          intent.kind == .paragraph
        else { return nil }
        return intent.identity
      })
    #expect(identities.count == (document.hasPrefix("Cited") ? 2 : 1))
    #expect(MemoryDocument.failures(in: Data(document.utf8)) == [diagnostic])
  }
}

@Test func observedBypassesFailCoreAndExecutableStorePaths() throws {
  for (document, diagnostic) in observedBypasses {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let base = try fixture.store.approvedCommit()
    let before = try fixture.humanState()
    let refs = try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"])
    #expect(throws: (any Error).self) {
      _ = try fixture.store.propose(
        base: base, path: "MEMORY.md", replacement: Data(document.utf8), reason: "Boundary fixture")
    }
    let rejected = try fixture.cli(
      [
        "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
        "Boundary fixture",
      ], input: Data(document.utf8))
    #expect(rejected.status != 0 && rejected.output.isEmpty)
    #expect(rejected.errorText.contains(diagnostic))
    #expect(try fixture.humanState() == before)
    #expect(try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"]) == refs)
    try fixture.write(document, path: "MEMORY.md")
    try fixture.commit()
    #expect(try fixture.store.check() == ["FAIL MEMORY.md: \(diagnostic)"])
    #expect(throws: (any Error).self) { try fixture.store.render(cwd: fixture.root) }
    let checked = try fixture.cli(["check", "--repo", fixture.repo.path])
    #expect(checked.status != 0 && checked.output.isEmpty)
    #expect(checked.errorText == "FAIL MEMORY.md: \(diagnostic)\n")
    let rendered = try fixture.cli([
      "render", "--repo", fixture.repo.path, "--cwd", fixture.root.path,
    ])
    #expect(rendered.status != 0 && rendered.output.isEmpty)
    #expect(rendered.errorText.contains(diagnostic))
  }
}

@Test func genuineReferenceDefinitionsAndTitleFormsAreExempt() {
  for definition in [
    "[rule]: docs/owner.md\n", "[rule]: <docs/owner.md>\n", "[rule]: <>\n",
    "[rule]: docs/(owner).md\n",
    "[rule]: docs/owner.md \"A title\"\n", "[rule]: docs/owner.md 'A title'\n",
    "[rule]: docs/owner.md (A title)\n", "[rule]:\n  docs/owner.md\n  \"A title\"\n",
    "[rule]: docs/owner.md\n  \"A multiline\n  title\"\n",
    "[a\\]b]: docs/owner.md\n", "> [rule]: docs/owner.md \"A title\"\n",
    "> > [rule]: docs/owner.md\n> >   'A title'\n",
    "[one]: docs/one.md\n[two]: docs/two.md\n",
  ] {
    for ending in ["\n", "\r\n"] {
      #expect(
        MemoryDocument.failures(
          in: Data(definition.replacingOccurrences(of: "\n", with: ending).utf8)
        ).isEmpty, "\(definition)")
    }
  }
}

@Test func malformedReferenceLookingParagraphsRequireAnnotations() {
  for document in [
    "[rule]: docs/owner.md Uncited fact\n", "[rule]: docs/owner.md \"Unclosed title\n",
    "[rule]: docs/owner.md \"Title\" extra\n", "[rule]: <docs/owner.md\n",
    "[rule]:\n", "[rule]: docs/owner.md (Unclosed title\n",
    "> [rule]: docs/owner.md Uncited fact\n",
  ] {
    #expect(
      MemoryDocument.failures(in: Data(document.utf8)) == [
        "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"
      ], "\(document)")
    #expect(
      MemoryDocument.failures(in: Data(fact(document.trimmingCharacters(in: .newlines)).utf8))
        .isEmpty)
  }
}

@Test func nativeQuoteNestingAndLazyContinuationHaveDistinctRequirements() {
  for document in [
    fact("Ordinary paragraph\n> Quoted paragraph"),
    fact("> Outer paragraph\n>> Nested paragraph"),
    fact("> Mixed depth\n>> continuation\n> final continuation"),
  ] {
    #expect(
      MemoryDocument.failures(in: Data(document.utf8)) == [
        "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"
      ])
  }
  for document in [
    fact("> First\nlazy continuation"),
    fact("> > Nested\n> lazy nested\nfully lazy continuation"),
    fact("- Item\n  continuation\nlazy item continuation"),
  ] {
    #expect(MemoryDocument.failures(in: Data(document.utf8)).isEmpty)
  }
}

@Test func exemptNodesStillValidateMalformedMetadata() {
  for document in [
    "# Header [source: owner]\n", "Header [source: owner]\n===\n",
    "[rule]: docs/owner.md \"[source: owner]\"\n",
    "> [rule]: docs/owner.md \"[source: owner]\"\n",
  ] {
    #expect(MemoryDocument.failures(in: Data(document.utf8)) == ["line 1: malformed metadata"])
  }
  for document in [
    "# Header [source: owner; added: 2024-02-30]\n",
    "[rule]: docs/owner.md \"[source: owner; added: 2024-02-30]\"\n",
  ] {
    #expect(
      MemoryDocument.failures(in: Data(document.utf8)) == [
        "line 1: added date is not a real calendar date"
      ])
  }
}

@Test func invisibleRawContentCannotBorrowReferenceExemptions() {
  for document in [
    "<!-- Uncited -->\n", "<div>\nUncited\n</div>\n", "```\nUncited code\n```\n",
    "[rule]: docs/owner.md\n\n<!-- Uncited -->\n", "[rule]: docs/owner.md\n\n-\n",
    "[rule]: docs/owner.md\n\n```\n```\n",
  ] {
    #expect(!MemoryDocument.failures(in: Data(document.utf8)).isEmpty, "\(document)")
  }
  #expect(
    MemoryDocument.failures(
      in: Data("<!-- Fact [source: owner; added: 2024-02-29] -->\n".utf8)
    ).isEmpty)
  #expect(
    MemoryDocument.failures(
      in: Data("```\nFact [source: owner; added: 2024-02-29]\n```\n".utf8)
    ).isEmpty)
}

@Test func referenceNormalizationPreservesUnicodeAndPhysicalDiagnostics() {
  let document =
    "# 🐢 Memory\n\n[rule]: docs/owner.md\n  \"Title\"\nUncited 🐢\n\n"
    + fact("> Cited 🐢\nlazy continuation") + ">\n> Uncited 🦊\n"
  for ending in ["\n", "\r\n", "\r", "\u{2028}"] {
    #expect(
      MemoryDocument.failures(
        in: Data(document.replacingOccurrences(of: "\n", with: ending).utf8)) == [
          "line 5: missing or malformed [source: reference; added: YYYY-MM-DD]",
          "line 10: missing or malformed [source: reference; added: YYYY-MM-DD]",
        ])
  }
  let quote = "> Uncited\n>\n> [rule]: docs/owner.md\n> Uncited 🐢\n"
  #expect(
    MemoryDocument.failures(in: Data(quote.utf8)) == [
      "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]",
      "line 4: missing or malformed [source: reference; added: YYYY-MM-DD]",
    ])
}

@Test func platformValidationDoesNotRewriteProposedCRLFBytes() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let raw =
    "# 🐢\r\n\r\n[rule]: docs/owner.md\r\n  \"Title\"\r\n"
    + fact("> Fact 🐢\nlazy continuation").replacingOccurrences(of: "\n", with: "\r\n")
  let bytes = Data(raw.utf8)
  let base = try fixture.store.approvedCommit()
  let proposed = try fixture.cli(
    [
      "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
      "Exact CRLF platform fixture",
    ], input: bytes)
  try #require(proposed.status == 0 && proposed.error.isEmpty)
  let commitLine = try #require(
    proposed.text.split(separator: "\n").first { $0.hasPrefix("commit: ") })
  let commit = String(commitLine.dropFirst(8))
  let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
  #expect(try git.data(["cat-file", "blob", "\(commit):MEMORY.md"]) == bytes)
  _ = try fixture.git(["update-ref", "refs/heads/main", commit, base])
  #expect(try Data(fixture.store.render(cwd: fixture.root).utf8) == bytes)
  let rendered = try fixture.cli([
    "render", "--repo", fixture.repo.path, "--cwd", fixture.root.path,
  ])
  #expect(rendered.status == 0 && rendered.error.isEmpty && rendered.output == bytes)
  #expect(try fixture.store.check().isEmpty)
  let checked = try fixture.cli(["check", "--repo", fixture.repo.path])
  #expect(checked.status == 0 && checked.output.isEmpty && checked.error.isEmpty)
}
