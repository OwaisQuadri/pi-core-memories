import Foundation
import Testing

@testable import CoreMemories

private func indexPreservationState(_ fixture: Fixture) throws -> [String: Data] {
  try fixture.snapshot(fixture.repo).filter {
    !$0.key.hasPrefix(".git/")
      || [".git/index", ".git/HEAD", ".git/config", ".git/refs/heads/main"].contains($0.key)
      || $0.key.hasPrefix(".git/sharedindex.")
  }
}

@Test(arguments: ["global", "existing-project", "new-project", "first-project"])
func directTreesPreserveUntouchedModesAndBytes(target: String) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
  let project = try fixture.project("selected-project")
  let key = try #require(try MemoryStore.projectKey(cwd: project))
  let projectPath = "projects/\(key).md"
  let otherPath = "projects/\(String(repeating: "a", count: 64)).md"
  let lastPath = "projects/\(String(repeating: "f", count: 64)).md"
  let global = fact("Approved global")
  let selected = fact("Approved selected project")
  try fixture.write(global, path: "MEMORY.md")
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: fixture.repo.appendingPathComponent("MEMORY.md").path)
  if target != "first-project" {
    try fixture.write(fact("Untouched executable project"), path: otherPath)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.repo.appendingPathComponent(otherPath).path)
    try fixture.write(fact("Untouched regular project"), path: lastPath)
  }
  if target == "existing-project" || target == "global" {
    try fixture.write(selected, path: projectPath)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.repo.appendingPathComponent(projectPath).path)
  }
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  let path = target == "global" ? "MEMORY.md" : projectPath
  let baseEntries = try fixture.git(["ls-tree", "-r", base]).split(separator: "\n").map(String.init)
  let approvedRender =
    global + ((target == "existing-project" || target == "global") ? "\n" + selected : "")
  let before = try indexPreservationState(fixture)
  let replacement = Data((fact("Replacement with exact bytes 🐢") + "\n\n").utf8)
  let proposal = try fixture.store.propose(
    base: base, path: path, replacement: replacement, reason: "direct tree")
  let duplicate = try fixture.store.propose(
    base: base, path: path, replacement: replacement, reason: "direct tree")
  #expect(proposal.commit == duplicate.commit && proposal.ref == duplicate.ref)
  #expect(proposal.base == base && duplicate.base == base)
  #expect(proposal.ref == "refs/heads/proposals/\(proposal.commit)")
  #expect(try fixture.git(["rev-parse", "\(proposal.commit)^1"]) == base)
  #expect(try fixture.git(["rev-parse", proposal.ref]) == proposal.commit)
  #expect(try git.data(["cat-file", "blob", "\(proposal.commit):\(path)"]) == replacement)
  let blob = try fixture.git(["hash-object", "--stdin", "--no-filters"], input: replacement)
  let targetEntry = "100644 blob \(blob)\t\(path)"
  let expectedEntries = (baseEntries.filter { !$0.hasSuffix("\t" + path) } + [targetEntry]).sorted {
    $0.split(separator: "\t")[1] < $1.split(separator: "\t")[1]
  }
  let actualEntries = try fixture.git(["ls-tree", "-r", proposal.commit]).split(separator: "\n")
    .map(String.init)
  #expect(actualEntries == expectedEntries)
  #expect(
    try git.data(["diff-tree", "-r", "--name-only", "-z", base, proposal.commit])
      == Data((path + "\0").utf8))
  #expect(try fixture.store.render(cwd: project) == approvedRender)
  #expect(try indexPreservationState(fixture) == before)
  #expect(try git.run(["fsck", "--strict", "--no-reflogs"]).status == 0)
  #expect(try fixture.store.review(commit: proposal.commit).contains("File: \(path)"))
}
