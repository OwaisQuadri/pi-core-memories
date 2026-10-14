import Foundation
import Testing

@testable import CoreMemories

private let uncitedBlockquoteCases: [(String, [Int])] = [
  (
    "> Uncited paragraph\n>\n> Cited paragraph [source: owner; added: 2024-02-29]\n",
    [1]
  ),
  (
    "> - Uncited item\n> - Cited item [source: owner; added: 2024-02-29]\n",
    [1]
  ),
  ("> Uncited\n> \t \n" + fact("> Cited"), [1]),
  ("> Uncited\n> # Heading\n" + fact("> Cited"), [1]),
  ("> Uncited\n>\n> [owner]: docs/owner.md\n" + fact("> Cited"), [1]),
  ("> Uncited\n> * * *\n" + fact("> Cited"), [1]),
  ("> Uncited\n> ___\n" + fact("> Cited"), [1]),
  ("> - Uncited\n>   continued\n> ---\n" + fact("> Cited"), [1]),
  ("> 1. Uncited\n>   continued\n> ----\n" + fact("> Cited"), [1]),
  ("> + Uncited\n" + fact("> * Cited"), [1]),
  ("> 2) Uncited\n" + fact("> 3. Cited"), [1]),
  (fact("> Cited\n> continued") + ">\n> Uncited\n> continued\n", [4]),
  ("> Uncited\n>\n> - Uncited item\n" + fact("> - Cited item"), [1, 3]),
]

private let malformedBlockquoteCases: [(String, String)] = [
  ("> Fact\n> continued [source: owner]\n", "malformed metadata"),
  ("> Fact\n> continued [source: owner; added: 2024-02-30]\n", "not a real calendar date"),
  ("> Fact\n> continued [source:   ; added: 2024-02-29]\n", "source reference must be nonempty"),
  ("> Fact [source: own\ter; added: 2024-02-29]\n", "contain no controls"),
  ("> # Heading [source: owner]\n", "malformed metadata"),
  ("> Memory [source: owner; added: 2024-02-30]\n> ===\n", "not a real calendar date"),
]

private let validBlockquoteDocuments = [
  fact("> Multiline 🐢\n> continued\n> with a final annotation"),
  fact("> Multiline\nlazy continuation\n> explicit continuation"),
  fact("> > Nested\n> lazy nested continuation\nfully lazy continuation"),
  fact("> - Multiline item\n>   continued\nlazy item continuation")
    + fact("> - Next item\n>   continued"),
  fact(">> 1. Nested ordered item\n>>    continued\n> lazy continuation")
    + fact(">> 2) Next item"),
  "> # Memory\n>\n" + fact("> Paragraph\n> continued") + "> \t\n"
    + fact("> Another paragraph") + "> [owner]: docs/owner.md\n",
  "> Memory\n> continued title\n> ===\n> # Heading\n"
    + fact("> - Cited\n>   continued") + "> ---\n" + fact("> Following"),
  "> Memory\n> ---\n" + fact("> Cited") + "> * * *\n> ___\n" + fact("> Following"),
]

@Test func blockquoteBoundariesRequireSeparateAnnotations() {
  for (document, lines) in uncitedBlockquoteCases {
    for prefix in [">", ">>", "> >", "  >", ">\t>"] {
      for ending in ["\n", "\r\n"] {
        let quoted = document.replacingOccurrences(of: ">", with: prefix)
          .replacingOccurrences(of: "\n", with: ending)
        #expect(
          MemoryDocument.failures(in: Data(quoted.utf8))
            == lines.map {
              "line \($0): missing or malformed [source: reference; added: YYYY-MM-DD]"
            }, "\(quoted)")
      }
    }
  }
}

@Test func blockquoteHeadingsAndListSeparatorsKeepExistingRules() {
  for prefix in [">", ">>", "> >"] {
    for heading in [
      "> # Memory\n", "> ###### Memory\n", "> Memory\n> ---\n",
      "> Memory\n> ======\n", "> Memory\n> continued\n> ---\n",
    ] {
      let document =
        heading + fact("> - Cited\n>   continued") + "> ---\n"
        + fact("> Following\n> continued")
      for ending in ["\n", "\r\n"] {
        let quoted = document.replacingOccurrences(of: ">", with: prefix)
          .replacingOccurrences(of: "\n", with: ending)
        #expect(MemoryDocument.failures(in: Data(quoted.utf8)).isEmpty, "\(quoted)")
      }
    }
  }
}

@Test func blockquoteMultilineAndLazyContinuationsRemainValid() {
  for document in validBlockquoteDocuments {
    for ending in ["\n", "\r\n"] {
      let quoted = document.replacingOccurrences(of: "\n", with: ending)
      #expect(MemoryDocument.failures(in: Data(quoted.utf8)).isEmpty, "\(quoted)")
    }
  }
  for document in [
    fact("> Single paragraph\n> still the same paragraph"),
    fact("> No space\n>before its annotation"),
    fact("> Uncited\n> [owner]: docs/owner.md\n> Cited"),
  ] {
    #expect(MemoryDocument.failures(in: Data(document.utf8)).isEmpty)
  }
  for document in [
    fact("> Mixed depth\n>> continuation\n> final continuation"),
    fact("Ordinary paragraph\n> quote-prefixed continuation"),
  ] {
    #expect(
      MemoryDocument.failures(in: Data(document.utf8)) == [
        "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"
      ])
  }
}

@Test func blockquoteMalformedAnnotationsRetainOriginalDiagnostics() {
  for (document, diagnostic) in malformedBlockquoteCases {
    for prefix in [">", "> >"] {
      for ending in ["\n", "\r\n"] {
        let quoted = document.replacingOccurrences(of: ">", with: prefix)
          .replacingOccurrences(of: "\n", with: ending)
        let failures = MemoryDocument.failures(in: Data(quoted.utf8))
        #expect(failures.contains(where: { $0.hasPrefix("line 1:") && $0.contains(diagnostic) }))
      }
    }
  }
  #expect(MemoryDocument.failures(in: Data([0x3e, 0x20, 0xff])) == ["invalid UTF-8"])
  #expect(
    MemoryDocument.failures(in: Data("> Fact\0\n".utf8)) == ["NUL is not allowed in Markdown"])
}

@Test func blockquoteBlankLinesRetainPhysicalLineNumbersAndNewlineSupport() {
  for ending in ["\n", "\r\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
    let document = "> # Memory\n> >\n> > Uncited\n> >\n" + fact("> > Cited\n> > continued")
    let bytes = Data(document.replacingOccurrences(of: "\n", with: ending).utf8)
    #expect(
      MemoryDocument.failures(in: bytes) == [
        "line 3: missing or malformed [source: reference; added: YYYY-MM-DD]"
      ])
    let valid = validBlockquoteDocuments[0].replacingOccurrences(of: "\n", with: ending)
    #expect(MemoryDocument.failures(in: Data(valid.utf8)).isEmpty)
  }
  let mixed = "> # Memory\r\n>\n> Uncited\r\n>\r\n" + fact("> Cited\n> continued")
  #expect(
    MemoryDocument.failures(in: Data(mixed.utf8)) == [
      "line 3: missing or malformed [source: reference; added: YYYY-MM-DD]"
    ])
}

private func invalidBlockquoteDocuments() -> [String] {
  (uncitedBlockquoteCases.map { $0.0 } + malformedBlockquoteCases.map { $0.0 }).flatMap {
    document in
    [">", "> >"].flatMap { prefix in
      ["\n", "\r\n"].map { ending in
        document.replacingOccurrences(of: ">", with: prefix)
          .replacingOccurrences(of: "\n", with: ending)
      }
    }
  }
}

@Test func coreInvalidBlockquoteProposalsPreserveHumanStateAndRefs() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let approved = fact("Approved\ncontinued")
  try fixture.write(approved, path: "MEMORY.md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  try fixture.write("Staged human edit", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Unstaged human edit", path: "MEMORY.md")
  try fixture.write("Untracked human file", path: "human.txt")
  let before = try fixture.humanState()
  let refs = try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"])
  for document in invalidBlockquoteDocuments() {
    #expect(throws: (any Error).self) {
      _ = try fixture.store.propose(
        base: base, path: "MEMORY.md", replacement: Data(document.utf8),
        reason: "Synthetic invalid blockquote candidate")
    }
    #expect(try fixture.humanState() == before)
    #expect(try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"]) == refs)
    #expect(try fixture.store.render(cwd: fixture.root) == approved)
  }
}

@Test func executableInvalidBlockquoteProposalsPreserveHumanStateAndRefs() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let approved = fact("Approved\ncontinued")
  try fixture.write(approved, path: "MEMORY.md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  try fixture.write("Staged human edit", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Unstaged human edit", path: "MEMORY.md")
  try fixture.write("Untracked human file", path: "human.txt")
  let before = try fixture.humanState()
  let refs = try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"])
  let arguments = [
    "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
    "Synthetic executable invalid blockquote candidate",
  ]
  for document in invalidBlockquoteDocuments() {
    let rejected = try fixture.cli(arguments, input: Data(document.utf8))
    #expect(rejected.status != 0 && rejected.output.isEmpty)
    let failures = MemoryDocument.failures(in: Data(document.utf8))
    #expect(!failures.isEmpty)
    for failure in failures { #expect(rejected.errorText.contains(failure)) }
    #expect(try fixture.humanState() == before)
    #expect(try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"]) == refs)
    #expect(try fixture.store.render(cwd: fixture.root) == approved)
  }
}

@Test func coreValidBlockquoteProposalsPreserveStoredAndRenderedBytes() throws {
  for document in validBlockquoteDocuments {
    for ending in ["\n", "\r\n"] {
      let fixture = try Fixture()
      defer { fixture.clean() }
      let base = try fixture.store.approvedCommit()
      let before = try fixture.humanState()
      let replacement = Data(document.replacingOccurrences(of: "\n", with: ending).utf8)
      let proposal = try fixture.store.propose(
        base: base, path: "MEMORY.md", replacement: replacement,
        reason: "Synthetic valid blockquote candidate")
      let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
      #expect(try git.data(["cat-file", "blob", "\(proposal.commit):MEMORY.md"]) == replacement)
      #expect(try fixture.humanState() == before)
      #expect(try fixture.store.render(cwd: fixture.root) == "# Memory\n")
      _ = try fixture.git(["update-ref", "refs/heads/main", proposal.commit, base])
      #expect(try Data(fixture.store.render(cwd: fixture.root).utf8) == replacement)
      #expect(try fixture.store.check().isEmpty)
    }
  }
}

@Test func executableValidBlockquoteProposalsPreserveStoredAndRenderedBytes() throws {
  for document in validBlockquoteDocuments {
    for ending in ["\n", "\r\n"] {
      let fixture = try Fixture()
      defer { fixture.clean() }
      let base = try fixture.store.approvedCommit()
      let before = try fixture.humanState()
      let replacement = Data(document.replacingOccurrences(of: "\n", with: ending).utf8)
      let proposed = try fixture.cli(
        [
          "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
          "Synthetic executable valid blockquote candidate",
        ], input: replacement)
      try #require(proposed.status == 0 && proposed.error.isEmpty)
      let commitLine = try #require(
        proposed.text.split(separator: "\n").first(where: { $0.hasPrefix("commit: ") }))
      let commit = String(commitLine.dropFirst(8))
      let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
      #expect(try git.data(["cat-file", "blob", "\(commit):MEMORY.md"]) == replacement)
      #expect(try fixture.humanState() == before)
      let renderArguments = ["render", "--repo", fixture.repo.path, "--cwd", fixture.root.path]
      #expect(try fixture.cli(renderArguments).output == Data("# Memory\n".utf8))
      _ = try fixture.git(["update-ref", "refs/heads/main", commit, base])
      let rendered = try fixture.cli(renderArguments)
      #expect(rendered.status == 0 && rendered.error.isEmpty)
      #expect(rendered.output == replacement)
      let checked = try fixture.cli(["check", "--repo", fixture.repo.path])
      #expect(checked.status == 0 && checked.output.isEmpty && checked.error.isEmpty)
    }
  }
}
