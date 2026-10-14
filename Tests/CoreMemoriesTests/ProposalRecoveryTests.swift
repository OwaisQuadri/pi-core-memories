import Foundation
import Testing

@testable import CoreMemories

private func recoveryState(_ fixture: Fixture) throws -> [String: Data] {
  try fixture.snapshot(fixture.repo).filter { !$0.key.hasPrefix(".git/objects/") }
}

@Test func exactProposalRecoverySurvivesHumanFastForward() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let replacement = Data((fact("Exact saved candidate 🐢") + "\n").utf8)
  let reason = "Saved reason\nwith Unicode 🐢"
  let contradictions = "Exact known conflict"
  let published = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
    contradictions: contradictions)
  let normal = try #require(
    try fixture.store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
      contradictions: contradictions))
  #expect(normal.ref == published.ref && normal.commit == published.commit && normal.base == base)
  _ = try fixture.git(["merge", "--ff-only", published.commit])
  #expect(try fixture.store.approvedCommit() == published.commit)
  try fixture.write("Staged human bytes", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Unstaged human bytes", path: "MEMORY.md")
  try fixture.write("Untracked human bytes", path: "human.txt")
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
      contradictions: contradictions)
  }
  let recovered = try #require(
    try fixture.store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
      contradictions: contradictions))
  #expect(recovered.ref == published.ref)
  #expect(recovered.commit == published.commit && recovered.base == base)
  #expect(
    try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/proposals/"])
      == published.ref)
  #expect(try fixture.snapshot(fixture.repo) == before)
}

@Test func absentProposalRecoveryWritesOnlyDeterministicObjects() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let replacement = Data(fact("Unpublished saved candidate").utf8)
  let before = try fixture.snapshot(fixture.repo)
  let objectsBefore = before.filter { $0.key.hasPrefix(".git/objects/") }
  #expect(
    try fixture.store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "saved") == nil)
  let after = try fixture.snapshot(fixture.repo)
  #expect(
    after.filter { !$0.key.hasPrefix(".git/objects/") }
      == before.filter { !$0.key.hasPrefix(".git/objects/") })
  let objectsAfter = after.filter { $0.key.hasPrefix(".git/objects/") }
  #expect(objectsAfter.count > objectsBefore.count)
  let published = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: "saved")
  _ = try fixture.git(["update-ref", "--no-deref", "-d", published.ref])
  #expect(try fixture.git(["cat-file", "-t", published.commit]) == "commit")
  try fixture.write(fact("Human advance without this proposal"), path: "MEMORY.md")
  try fixture.commit()
  let staleBefore = try fixture.snapshot(fixture.repo)
  #expect(
    try fixture.store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "saved") == nil)
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "saved")
  }
  #expect(try fixture.snapshot(fixture.repo) == staleBefore)
}

@Test(arguments: ["replacement", "reason", "contradictions", "base", "path"])
func recoveryRequiresEveryExactPlanField(field: String) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let replacement = Data(fact("Saved candidate").utf8)
  let published = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: "saved",
    contradictions: "conflict")
  _ = try fixture.git(["merge", "--ff-only", published.commit])
  let before = try recoveryState(fixture)
  let recovered = try fixture.store.recoverProposal(
    base: field == "base" ? published.commit : base,
    path: field == "path" ? "projects/\(String(repeating: "a", count: 64)).md" : "MEMORY.md",
    replacement: field == "replacement" || field == "base"
      ? Data(fact("Other candidate").utf8) : replacement,
    reason: field == "reason" ? "other reason" : "saved",
    contradictions: field == "contradictions" ? "other conflict" : "conflict")
  #expect(recovered == nil)
  #expect(try recoveryState(fixture) == before)
}

@Test(arguments: [
  "symbolic", "dangling-symbolic", "conflict", "parent", "metadata", "mode", "path",
  "malformed-ref",
])
func recoveryBlocksUnsafeExactRefsWithoutMutation(kind: String) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let replacement = Data(fact("Saved candidate").utf8)
  let published = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: "saved")
  _ = try fixture.git(["update-ref", "--no-deref", "-d", published.ref])
  if kind == "symbolic" || kind == "dangling-symbolic" {
    if kind == "symbolic" {
      _ = try fixture.git(["update-ref", "refs/heads/human", published.commit])
    }
    _ = try fixture.git(["symbolic-ref", published.ref, "refs/heads/human"])
  } else if kind == "malformed-ref" {
    try fixture.write("not an object identifier\n", path: ".git/\(published.ref)")
  } else {
    var commit = base
    if kind != "conflict" {
      var tree = try fixture.git(["rev-parse", "\(published.commit)^{tree}"])
      if kind == "mode" || kind == "path" {
        let blob = try fixture.git(["hash-object", "-w", "--stdin"], input: replacement)
        let path = kind == "path" ? "other.md" : "MEMORY.md"
        let mode = kind == "mode" ? "100755" : "100644"
        tree = try fixture.git(
          ["mktree", "-z"], input: Data("\(mode) blob \(blob)\t\(path)\0".utf8))
      }
      let raw = try fixture.git(["cat-file", "commit", published.commit])
      let separator = try #require(raw.range(of: "\n\n"))
      let message =
        kind == "metadata" ? "Malformed proposal metadata\n" : String(raw[separator.upperBound...])
      let parents = kind == "parent" ? [] : ["-p", base]
      commit = try fixture.git(["commit-tree", tree] + parents, input: Data(message.utf8))
    }
    _ = try fixture.git(["update-ref", published.ref, commit])
  }
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    _ = try fixture.store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "saved")
  }
  #expect(try fixture.snapshot(fixture.repo) == before)
}

@Test func recoveryMissingBaseTreeNeverFetchesOrPublishes() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let replacement = Data(fact("Saved candidate").utf8)
  let published = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: "saved")
  let transport = fixture.root.appendingPathComponent("remote-command")
  let invoked = fixture.root.appendingPathComponent("transport-invoked")
  try fixture.write(
    "#!/bin/zsh\nprint -rn -- invoked > '\(invoked.path)'\nexit 1\n",
    path: transport.lastPathComponent, at: fixture.root)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transport.path)
  for setting in [
    ["extensions.partialClone", "origin"], ["remote.origin.promisor", "true"],
    ["remote.origin.url", "ext::\(transport.path)"], ["protocol.ext.allow", "always"],
  ] {
    _ = try fixture.git(["config"] + setting)
  }
  let tree = try fixture.git(["rev-parse", "\(base)^{tree}"])
  let object = fixture.repo.appendingPathComponent(
    ".git/objects/\(tree.prefix(2))/\(tree.dropFirst(2))")
  try FileManager.default.removeItem(at: object)
  var environment = ProcessInfo.processInfo.environment
  environment["GIT_NO_LAZY_FETCH"] = "0"
  let store = try MemoryStore(repo: fixture.repo, environment: environment)
  let before = try fixture.snapshot(fixture.root)
  #expect(throws: (any Error).self) {
    _ = try store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "saved")
  }
  #expect(try fixture.snapshot(fixture.root) == before)
  #expect(!FileManager.default.fileExists(atPath: invoked.path))
  #expect(try fixture.git(["rev-parse", published.ref]) == published.commit)
}

@Test func recoveryPreservesGitIsolationAndDisablesLocalExecution() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let other = try fixture.project("other")
  let base = try fixture.store.approvedCommit()
  let replacement = Data(fact("Saved candidate").utf8)
  let published = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: "saved")
  let sentinel = fixture.root.appendingPathComponent("executed")
  let script = fixture.root.appendingPathComponent("hostile-command")
  try fixture.write(
    "#!/bin/sh\ntouch '\(sentinel.path)'\nexit 1\n", path: script.lastPathComponent,
    at: fixture.root)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  _ = try fixture.git(["config", "core.fsmonitor", script.path])
  _ = try fixture.git(["config", "core.hooksPath", fixture.root.path])
  try fixture.write(
    "#!/bin/sh\ntouch '\(sentinel.path)'\nexit 1\n", path: "reference-transaction", at: fixture.root
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: fixture.root.appendingPathComponent("reference-transaction").path)
  _ = try fixture.git(["config", "commit.gpgsign", "true"])
  _ = try fixture.git(["config", "gpg.program", script.path])
  _ = try fixture.git(["config", "remote.fixture.promisor", "true"])
  _ = try fixture.git([
    "config", "remote.fixture.url", fixture.root.appendingPathComponent("missing-remote").path,
  ])
  var environment = ProcessInfo.processInfo.environment.merging(hostileEnvironment(other: other)) {
    _, new in new
  }
  environment["GIT_NO_LAZY_FETCH"] = "0"
  let store = try MemoryStore(repo: fixture.repo, environment: environment)
  let before = try fixture.snapshot(fixture.repo)
  let otherBefore = try fixture.snapshot(other)
  let recovered = try #require(
    try store.recoverProposal(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "saved"))
  #expect(recovered.commit == published.commit)
  #expect(try fixture.snapshot(fixture.repo) == before)
  #expect(try fixture.snapshot(other) == otherBefore)
  #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}
