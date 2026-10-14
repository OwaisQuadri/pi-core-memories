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

private func aliasPermissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777
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

@Test(arguments: ["", "/", "/.", "/./", "//.", "/././"], [false, true])
func finalDestinationAliasesAreRejected(suffix: String, isExecutable: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  for isOccupied in [false, true] {
    let target = fixture.root.appendingPathComponent(
      isOccupied ? "occupied target" : "empty target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    if isOccupied {
      try fixture.write("Human bytes", path: "keep", at: target)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: target.appendingPathComponent("keep").path)
    }
    let alias = fixture.root.appendingPathComponent(isOccupied ? "occupied alias" : "empty alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    let destination = URL(fileURLWithPath: alias.path + suffix)
    #expect(destination.standardizedFileURL.path == alias.path)
    #expect(destination.resolvingSymlinksInPath().path == target.path)
    let before = try fixture.snapshot(target)
    let mode = try aliasPermissions(alias)
    if isExecutable {
      let result = try fixture.cli(["init", "--repo", alias.path + suffix])
      #expect(result.status != 0 && result.output.isEmpty)
      #expect(result.errorText.contains("refusing a symlink path"))
    } else {
      let error = #expect(throws: MemoryError.self) {
        try MemoryStore.initialize(repo: destination)
      }
      #expect(error?.description == "refusing a symlink path")
    }
    #expect(try fixture.snapshot(target) == before)
    #expect(try aliasPermissions(target) == 0o755)
    #expect(try aliasPermissions(alias) == mode)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == target.path)
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path))
    if isOccupied {
      #expect(try aliasPermissions(target.appendingPathComponent("keep")) == 0o644)
    }
  }
  let absent = fixture.root.appendingPathComponent("absent")
  let dangling = fixture.root.appendingPathComponent("dangling")
  try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: absent)
  let mode = try aliasPermissions(dangling)
  if isExecutable {
    let result = try fixture.cli(["init", "--repo", dangling.path + suffix])
    #expect(result.status != 0 && result.output.isEmpty)
    #expect(result.errorText.contains("refusing a symlink path"))
  } else {
    let error = #expect(throws: MemoryError.self) {
      try MemoryStore.initialize(repo: URL(fileURLWithPath: dangling.path + suffix))
    }
    #expect(error?.description == "refusing a symlink path")
  }
  #expect(try aliasPermissions(dangling) == mode)
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == absent.path)
  #expect(!FileManager.default.fileExists(atPath: absent.path))
}

@Test(arguments: ["", "/", "/.", "/./", "//.", "/././"], [false, true])
func ordinaryDestinationSpellingsRemainAccepted(suffix: String, isExecutable: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  for isExisting in [false, true] {
    let repo = fixture.root.appendingPathComponent(isExisting ? "existing" : "new")
    if isExisting {
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path)
    }
    if isExecutable {
      let result = try fixture.cli(["init", "--repo", repo.path + suffix])
      #expect(result.status == 0 && result.output.isEmpty && result.error.isEmpty)
    } else {
      try MemoryStore.initialize(repo: URL(fileURLWithPath: repo.path + suffix))
    }
    #expect(try aliasPermissions(repo) == 0o700)
    #expect(try aliasPermissions(repo.appendingPathComponent("MEMORY.md")) == 0o600)
    #expect(try MemoryStore(repo: repo).render(cwd: fixture.root) == "# Memory\n")
  }
}

@Test(arguments: [false, true])
func ancestorAndSystemAliasesRemainAccepted(isExecutable: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let parent = fixture.root.appendingPathComponent("real parent")
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
  let alias = fixture.root.appendingPathComponent("parent alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
  let systemAlias = FileManager.default.temporaryDirectory.appendingPathComponent(
    fixture.root.lastPathComponent)
  #expect(systemAlias.resolvingSymlinksInPath().path == fixture.root.path)
  for destination in [
    URL(fileURLWithPath: alias.appendingPathComponent("new").path + "/."),
    URL(fileURLWithPath: alias.appendingPathComponent("empty").path + "/./"),
    URL(fileURLWithPath: systemAlias.appendingPathComponent("system store").path + "/."),
  ] {
    let canonical = destination.resolvingSymlinksInPath()
    if canonical.lastPathComponent == "empty" {
      try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: canonical.path)
    }
    if isExecutable {
      let result = try fixture.cli(["init", "--repo", destination.path])
      #expect(result.status == 0 && result.output.isEmpty && result.error.isEmpty)
    } else {
      try MemoryStore.initialize(repo: destination)
    }
    #expect(try aliasPermissions(canonical) == 0o700)
    #expect(try aliasPermissions(canonical.appendingPathComponent("MEMORY.md")) == 0o600)
    #expect(try MemoryStore(repo: canonical).render(cwd: fixture.root) == "# Memory\n")
  }
  #expect(try aliasPermissions(parent) == 0o755)
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == parent.path)
}
