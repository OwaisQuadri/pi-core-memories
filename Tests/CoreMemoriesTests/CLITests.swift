import Foundation
import Testing

@testable import CoreMemories

@Test func executableCommandContracts() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let fresh = fixture.root.appendingPathComponent("cli data")
  let initialized = try fixture.cli(["init", "--repo", fresh.path])
  #expect(initialized.status == 0)
  #expect(initialized.output.isEmpty && initialized.error.isEmpty)
  let check = try fixture.cli(["check", "--repo", fresh.path])
  #expect(check.status == 0)
  #expect(check.output.isEmpty && check.error.isEmpty)
  let render = try fixture.cli(["render", "--repo", fresh.path, "--cwd", fixture.root.path])
  #expect(render.status == 0 && render.text == "# Memory\n" && render.error.isEmpty)
  let outsideKey = try fixture.cli(["project-key", "--cwd", fixture.root.path])
  #expect(outsideKey.status != 0 && outsideKey.output.isEmpty)
  #expect(outsideKey.errorText.contains("no project key exists"))
  let key = try fixture.cli(["project-key", "--cwd", fixture.repo.path])
  #expect(key.status == 0)
  #expect(key.text == (try #require(try MemoryStore.projectKey(cwd: fixture.repo))) + "\n")
  let missing = fixture.root.appendingPathComponent("missing-cli")
  for command in ["render", "check"] {
    let arguments =
      [command, "--repo", missing.path] + (command == "render" ? ["--cwd", fixture.root.path] : [])
    let result = try fixture.cli(arguments)
    #expect(result.status != 0 && result.output.isEmpty)
    #expect(result.errorText.hasPrefix("FAIL "))
    #expect(!FileManager.default.fileExists(atPath: missing.path))
  }
  let before = try fixture.snapshot(fixture.repo)
  let refused = try fixture.cli(["init", "--repo", fixture.repo.path])
  #expect(refused.status != 0 && refused.errorText.hasPrefix("FAIL "))
  #expect(try fixture.snapshot(fixture.repo) == before)
  let symlink = fixture.root.appendingPathComponent("cli-link")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.repo)
  #expect(try fixture.cli(["init", "--repo", symlink.path]).status != 0)
  #expect(
    try fixture.cli(["init", "--repo", fixture.repo.appendingPathComponent("nested").path]).status
      != 0)
  for arguments in [
    [String](), ["approve"], ["check"],
    ["check", "--repo", fresh.path, "--cwd", fixture.root.path],
    ["check", "--repo", fresh.path, "--repo", fresh.path],
  ] {
    #expect(try fixture.cli(arguments).status != 0)
  }
}

@Test func executableProposalsAndReview() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let project = try fixture.project("cli-project")
  let key = try #require(try MemoryStore.projectKey(cwd: project))
  let otherKey = String(repeating: "f", count: 64)
  try fixture.write(fact("CLI approved global"), path: "MEMORY.md")
  try fixture.write(fact("CLI approved project"), path: "projects/\(key).md")
  try fixture.write(fact("CLI unrelated secret"), path: "projects/\(otherKey).md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  try fixture.write("Staged CLI human edit", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Unstaged CLI human edit", path: "MEMORY.md")
  try fixture.write("Human untracked", path: "human.txt")
  let before = try fixture.humanState()
  let arguments = [
    "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
    "CLI reason\nwith two lines", "--contradictions", "CLI contradiction",
  ]
  let replacement = Data(fact("CLI candidate").utf8)
  let proposed = try fixture.cli(arguments, input: replacement)
  #expect(proposed.status == 0 && proposed.error.isEmpty)
  let fields = Dictionary(
    uniqueKeysWithValues: proposed.text.split(separator: "\n").map { line in
      let parts = line.split(separator: " ", maxSplits: 1)
      return (String(parts[0]), String(parts[1]))
    })
  let commit = try #require(fields["commit:"])
  let ref = try #require(fields["ref:"])
  #expect(fields["base:"] == base)
  #expect(ref == "refs/heads/proposals/\(commit)")
  #expect(try fixture.cli(arguments, input: replacement).text == proposed.text)
  let review = try fixture.cli(["review", "--repo", fixture.repo.path, commit])
  #expect(review.status == 0 && review.error.isEmpty)
  #expect(review.text == (try fixture.store.review(commit: commit)))
  #expect(review.text.contains("CLI reason\nwith two lines"))
  #expect(try fixture.humanState() == before)
  let rendered = try fixture.cli(["render", "--repo", fixture.repo.path, "--cwd", project.path])
  #expect(rendered.status == 0)
  #expect(rendered.text == fact("CLI approved global") + "\n" + fact("CLI approved project"))
  for path in [
    "../source/MEMORY.md", ".git/config", ".git/index", "projects/../MEMORY.md",
    fixture.repo.appendingPathComponent("MEMORY.md").path,
  ] {
    let unsafe = [
      "propose", "--repo", fixture.repo.path, "--base", base, "--file", path, "--reason", "unsafe",
    ]
    let result = try fixture.cli(unsafe, input: replacement)
    #expect(result.status != 0 && result.output.isEmpty && result.errorText.hasPrefix("FAIL "))
  }
  for invalid in [
    Data([0xff]), Data("Missing metadata".utf8), Data("Fact [source: ; added: 2026-01-01]".utf8),
  ] {
    #expect(try fixture.cli(arguments, input: invalid).status != 0)
  }
  #expect(try fixture.humanState() == before)
  try fixture.write(fact("CLI approved global"), path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  _ = try fixture.git(["switch", "--detach", commit])
  try fixture.write("Dirty proposal checkout", path: "MEMORY.md")
  #expect(
    try fixture.cli(["render", "--repo", fixture.repo.path, "--cwd", project.path]).text
      == rendered.text)
  _ = try fixture.git(["update-ref", "refs/heads/main", commit, base])
  #expect(try fixture.cli(arguments, input: replacement).status != 0)
}
