import Foundation
import Testing

@testable import CoreMemories

private func hookProtectedState(_ fixture: Fixture, at repo: URL) throws -> [String: Data] {
  var state = try fixture.snapshot(repo).filter {
    !$0.key.hasPrefix(".git/") || [".git/index", ".git/HEAD", ".git/config"].contains($0.key)
  }
  state["../human.txt"] = try Data(contentsOf: fixture.root.appendingPathComponent("human.txt"))
  return state
}

@Test(arguments: [false, true])
func externalFSMonitorCannotChangeHumanState(isExecutable: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let repo = isExecutable ? fixture.root.appendingPathComponent("cli store") : fixture.repo
  if isExecutable {
    let initialized = try fixture.cli(["init", "--repo", repo.path])
    try #require(initialized.status == 0 && initialized.output.isEmpty && initialized.error.isEmpty)
  }
  try fixture.write(fact("Staged human memory"), path: "MEMORY.md", at: repo)
  _ = try fixture.git(["add", "MEMORY.md"], at: repo)
  try fixture.write(fact("Unstaged human memory"), path: "MEMORY.md", at: repo)
  try fixture.write("Untracked human bytes", path: "local.txt", at: repo)
  try fixture.write("original", path: "human.txt", at: fixture.root)
  let monitor = fixture.root.appendingPathComponent("external-monitor")
  let marker = fixture.root.appendingPathComponent("monitor-runs")
  try fixture.write(
    """
    #!/bin/zsh
    print -rn -- overwritten > "${0:A:h}/human.txt"
    print -r -- ran >> "${0:A:h}/monitor-runs"
    printf 'fixture-token\\0'
    """, path: monitor.lastPathComponent, at: fixture.root)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: monitor.path)
  _ = try fixture.git(["config", "core.fsmonitor", monitor.path], at: repo)
  let control = try runCommand(
    executable: URL(fileURLWithPath: "/usr/bin/git"),
    arguments: ["-C", repo.path, "-c", "core.hooksPath=/dev/null", "status", "--porcelain=v1"],
    environment: Git(repo: repo, environment: ProcessInfo.processInfo.environment).environment)
  try #require(control.status == 0 && control.error.isEmpty)
  try #require(
    try Data(contentsOf: fixture.root.appendingPathComponent("human.txt"))
      == Data("overwritten".utf8))
  try #require(FileManager.default.fileExists(atPath: marker.path))
  try fixture.write("original", path: "human.txt", at: fixture.root)
  try FileManager.default.removeItem(at: marker)
  let before = try hookProtectedState(fixture, at: repo)
  let store = try MemoryStore(repo: repo)
  let base = try store.approvedCommit()
  let replacement = Data(fact("Monitor-free candidate").utf8)
  let commit: String
  if isExecutable {
    let arguments = [
      "propose", "--repo", repo.path, "--base", base, "--file", "MEMORY.md",
      "--reason", "Monitor boundary",
    ]
    let created = try fixture.cli(arguments, input: replacement)
    try #require(created.status == 0 && created.error.isEmpty)
    let commitLine = try #require(
      created.text.split(separator: "\n").first { $0.hasPrefix("commit: ") })
    commit = String(commitLine.dropFirst(8))
    #expect(created.text.contains("ref: refs/heads/proposals/\(commit)\n"))
    #expect(created.text.contains("base: \(base)\n"))
    #expect(try hookProtectedState(fixture, at: repo) == before)
    let duplicate = try fixture.cli(arguments, input: replacement)
    #expect(duplicate.status == 0 && duplicate.error.isEmpty && duplicate.output == created.output)
  } else {
    let created = try store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "Monitor boundary")
    commit = created.commit
    #expect(created.ref == "refs/heads/proposals/\(commit)" && created.base == base)
    #expect(try hookProtectedState(fixture, at: repo) == before)
    let duplicate = try store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "Monitor boundary")
    #expect(duplicate.ref == created.ref && duplicate.commit == commit && duplicate.base == base)
  }
  #expect(try hookProtectedState(fixture, at: repo) == before)
  if isExecutable {
    let review = try fixture.cli(["review", "--repo", repo.path, commit])
    #expect(
      review.status == 0 && review.error.isEmpty && review.text.contains("Monitor-free candidate"))
    #expect(try hookProtectedState(fixture, at: repo) == before)
    let render = try fixture.cli(["render", "--repo", repo.path, "--cwd", fixture.root.path])
    #expect(render.status == 0 && render.error.isEmpty && render.text == "# Memory\n")
    #expect(try hookProtectedState(fixture, at: repo) == before)
    let check = try fixture.cli(["check", "--repo", repo.path])
    #expect(check.status == 0 && check.output.isEmpty && check.error.isEmpty)
    #expect(try hookProtectedState(fixture, at: repo) == before)
    let key = try fixture.cli(["project-key", "--cwd", repo.path])
    let expectedKey = try #require(try MemoryStore.projectKey(cwd: repo))
    #expect(key.status == 0 && key.error.isEmpty && key.text == expectedKey + "\n")
  } else {
    #expect(try store.review(commit: commit).contains("Monitor-free candidate"))
    #expect(try hookProtectedState(fixture, at: repo) == before)
    #expect(try store.render(cwd: fixture.root) == "# Memory\n")
    #expect(try hookProtectedState(fixture, at: repo) == before)
    #expect(try store.check().isEmpty)
    #expect(try hookProtectedState(fixture, at: repo) == before)
    #expect(try MemoryStore.projectKey(cwd: repo) != nil)
  }
  #expect(try store.approvedCommit() == base)
  #expect(try hookProtectedState(fixture, at: repo) == before)
  #expect(!FileManager.default.fileExists(atPath: marker.path))
}
