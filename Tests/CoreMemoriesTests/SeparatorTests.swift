import Foundation
import Testing

@testable import CoreMemories

private let separatorListPrefixes = ["-", "+", "*", "1.", "2)", "  -", "  3."]

private func uncitedSeparatorDocuments() -> [String] {
  var documents: [String] = []
  for prefix in separatorListPrefixes {
    for continuation in ["", "  continued\n"] {
      let document = "\(prefix) Uncited\n\(continuation)---\n" + fact("Following\ncontinued")
      documents.append(document)
      documents.append(document.replacingOccurrences(of: "\n", with: "\r\n"))
    }
  }
  return documents
}

@Test func uncitedListItemsBeforeHyphenBreaksRequireAnnotations() {
  for prefix in separatorListPrefixes {
    for separator in ["---", "----", "- - -"] {
      let document = "\(prefix) Uncited\n\(separator)\n" + fact("Following\ncontinued")
      for ending in ["\n", "\r\n"] {
        let bytes = Data(document.replacingOccurrences(of: "\n", with: ending).utf8)
        #expect(
          MemoryDocument.failures(in: bytes) == [
            "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"
          ])
      }
    }
  }
}

@Test func citedListItemsBeforeHyphenBreaksRemainValid() {
  for prefix in separatorListPrefixes {
    for separator in ["---", "----", "- - -"] {
      let document =
        fact("\(prefix) Cited\n  continued") + "\(separator)\n"
        + fact("Following\ncontinued")
      for ending in ["\n", "\r\n"] {
        let bytes = Data(document.replacingOccurrences(of: "\n", with: ending).utf8)
        #expect(MemoryDocument.failures(in: bytes).isEmpty)
      }
    }
  }
}

@Test func genuineHeadingsRemainAnnotationFreeAroundSeparators() {
  for heading in [
    "Memory\n---\n", "Memory\n======\n", "Memory\ncontinued\n---\n",
    "# Memory\n", "###### Memory\n", "# Memory\n\n---\n",
  ] {
    let document =
      heading + fact("- Cited\n  continued") + "---\n"
      + fact("Following\ncontinued")
    for ending in ["\n", "\r\n"] {
      let bytes = Data(document.replacingOccurrences(of: "\n", with: ending).utf8)
      #expect(MemoryDocument.failures(in: bytes).isEmpty)
    }
  }
}

@Test func separatorsKeepMultilineListAndFactBoundaries() {
  let cases: [(String, [Int])] = [
    (
      "- Uncited\n  continued\n---\n" + fact("- Cited\n  continued") + "----\n"
        + fact("Following\ncontinued"), [1]
    ),
    (fact("- Cited\n  continued") + "---\nUncited fact\ncontinued\n", [4]),
    ("Uncited fact\ncontinued\n\n---\n" + fact("- Cited\n  continued"), [1]),
    (
      "Uncited fact\ncontinued\n1. Uncited list\n   continued\n---\n" + fact("Following"),
      [1, 3]
    ),
    ("Uncited fact\n- - -\n" + fact("Following\ncontinued"), [1]),
    (
      fact("- Cited\n  continued") + "---\n- Uncited\n  continued\n---\n"
        + fact("- Following\n  continued"), [4]
    ),
  ]
  for (document, lines) in cases {
    for ending in ["\n", "\r\n"] {
      let bytes = Data(document.replacingOccurrences(of: "\n", with: ending).utf8)
      #expect(
        MemoryDocument.failures(in: bytes)
          == lines.map {
            "line \($0): missing or malformed [source: reference; added: YYYY-MM-DD]"
          })
    }
  }
}

@Test func coreUncitedSeparatorProposalsPreserveHumanStateAndRefs() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write(fact("Approved\ncontinued"), path: "MEMORY.md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  try fixture.write("Staged human edit", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Unstaged human edit", path: "MEMORY.md")
  try fixture.write("Untracked human file", path: "human.txt")
  let before = try fixture.humanState()
  let refs = try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"])
  for document in uncitedSeparatorDocuments() {
    #expect(throws: (any Error).self) {
      _ = try fixture.store.propose(
        base: base, path: "MEMORY.md", replacement: Data(document.utf8),
        reason: "Synthetic uncited separator candidate")
    }
    #expect(try fixture.humanState() == before)
    #expect(try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"]) == refs)
    #expect(try fixture.store.render(cwd: fixture.root) == fact("Approved\ncontinued"))
  }
}

@Test func executableUncitedSeparatorProposalsPreserveHumanStateAndRefs() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write(fact("Approved\ncontinued"), path: "MEMORY.md")
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
    "Synthetic executable uncited separator candidate",
  ]
  for document in uncitedSeparatorDocuments() {
    let rejected = try fixture.cli(arguments, input: Data(document.utf8))
    #expect(rejected.status != 0 && rejected.output.isEmpty)
    #expect(
      rejected.errorText.contains(
        "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"))
    #expect(try fixture.humanState() == before)
    #expect(try fixture.git(["for-each-ref", "--format=%(refname) %(objectname)"]) == refs)
    #expect(try fixture.store.render(cwd: fixture.root) == fact("Approved\ncontinued"))
  }
}

@Test func executableSeparatorProposalsPreserveStoredAndRenderedBytes() throws {
  let documents = [
    fact("- Cited\n  continued") + "---\n" + fact("Following\ncontinued"),
    fact("1. Cited\n   continued") + "---\n" + fact("- Following\n  continued"),
    "Memory\n---\n" + fact("- Cited\n  continued") + "---\n",
    "Memory\n======\n# Heading\n" + fact("Following\ncontinued") + "\n---\n",
  ]
  for document in documents {
    for ending in ["\n", "\r\n"] {
      let fixture = try Fixture()
      defer { fixture.clean() }
      let base = try fixture.store.approvedCommit()
      let before = try fixture.humanState()
      let replacement = Data(document.replacingOccurrences(of: "\n", with: ending).utf8)
      let proposed = try fixture.cli(
        [
          "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
          "Synthetic executable separator candidate",
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
    }
  }
}
