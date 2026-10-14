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

private func stageHumanEdits(_ fixture: Fixture, isSplit: Bool) throws -> [String] {
  _ = try fixture.git(["config", "core.splitIndex", isSplit ? "true" : "false"])
  try fixture.write("Staged human memory", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Staged human file", path: "human-staged.txt")
  _ = try fixture.git(["add", "human-staged.txt"])
  try fixture.write("Unstaged human memory", path: "MEMORY.md")
  try fixture.write("Untracked human file", path: "human-untracked.txt")
  let paths = try fixture.snapshot(fixture.repo).keys.filter { $0.hasPrefix(".git/sharedindex.") }
  #expect(isSplit ? !paths.isEmpty : paths.isEmpty)
  return Array(paths)
}

private func ageSharedIndexes(_ fixture: Fixture, paths: [String]) throws {
  for path in paths {
    let url = fixture.repo.appendingPathComponent(path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: 0))
  }
}

private func cliProposalCommit(_ result: CommandResult) throws -> String {
  let line = try #require(
    result.text.split(separator: "\n").first(where: { $0.hasPrefix("commit: ") }))
  return String(line.dropFirst(8))
}

@Test(arguments: [false, true], [false, true])
func proposalsPreservePlainAndAgedSplitIndexes(isSplit: Bool, isCLI: Bool) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
  let base = try fixture.store.approvedCommit()
  let sharedPaths = try stageHumanEdits(fixture, isSplit: isSplit)
  let humanBefore = try fixture.humanState()
  let stagedBefore = try git.data(["ls-files", "--stage", "-z"])
  let stagedDiffBefore = try git.data(["diff", "--cached", "--binary", base, "--"])
  try ageSharedIndexes(fixture, paths: sharedPaths)
  let before = try indexPreservationState(fixture)
  let replacement = Data((fact("Exact candidate 🐢") + "\n\n").utf8)
  var commit: String?
  if isCLI {
    let result = try fixture.cli(
      [
        "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
        "index preservation",
      ], input: replacement)
    #expect(result.status == 0, "\(result.errorText)")
    #expect(result.error.isEmpty)
    if result.status == 0 { commit = try cliProposalCommit(result) }
  } else {
    #expect(throws: Never.self) {
      commit = try fixture.store.propose(
        base: base, path: "MEMORY.md", replacement: replacement, reason: "index preservation"
      ).commit
    }
  }
  #expect(try indexPreservationState(fixture) == before)
  let stagedAfter = try git.run(["ls-files", "--stage", "-z"])
  #expect(stagedAfter.status == 0, "\(stagedAfter.errorText)")
  #expect(stagedAfter.output == stagedBefore)
  if stagedAfter.status == 0 {
    #expect(try git.data(["show", ":MEMORY.md"]) == Data("Staged human memory".utf8))
    #expect(try git.data(["show", ":human-staged.txt"]) == Data("Staged human file".utf8))
    #expect(try git.data(["diff", "--cached", "--binary", base, "--"]) == stagedDiffBefore)
    #expect(try fixture.humanState() == humanBefore)
  }
  #expect(try fixture.store.approvedCommit() == base)
  #expect(try fixture.store.render(cwd: fixture.root) == "# Memory\n")
  if let commit {
    #expect(try git.data(["cat-file", "blob", "\(commit):MEMORY.md"]) == replacement)
    #expect(try fixture.git(["rev-parse", "\(commit)^1"]) == base)
    #expect(try fixture.git(["diff-tree", "-r", "--name-only", base, commit]) == "MEMORY.md")
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

@Test(arguments: [false, true])
func concurrentDirectTreesPreserveAgedSplitIndexes(isCLI: Bool) async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let sharedPaths = try stageHumanEdits(fixture, isSplit: true)
  let git = Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
  let stagedBefore = try git.data(["ls-files", "--stage", "-z"])
  try ageSharedIndexes(fixture, paths: sharedPaths)
  let before = try indexPreservationState(fixture)
  let projectPath = "projects/\(String(repeating: "b", count: 64)).md"
  let commits = try await withThrowingTaskGroup(of: (String, String, Data).self) { group in
    for index in 0..<6 {
      group.addTask {
        let path = index == 3 ? "MEMORY.md" : projectPath
        let replacement = Data(fact(index < 3 ? "Identical project" : "Candidate \(index)").utf8)
        let commit: String
        if isCLI {
          let result = try fixture.cli(
            [
              "propose", "--repo", fixture.repo.path, "--base", base, "--file", path,
              "--reason", "concurrent direct tree",
            ], input: replacement)
          try #require(result.status == 0, "\(result.errorText)")
          commit = try cliProposalCommit(result)
        } else {
          commit = try fixture.store.propose(
            base: base, path: path, replacement: replacement, reason: "concurrent direct tree"
          ).commit
        }
        return (commit, path, replacement)
      }
    }
    var commits: [(String, String, Data)] = []
    for try await commit in group { commits.append(commit) }
    return commits
  }
  #expect(Set(commits.map { $0.0 }).count == 4)
  #expect(
    try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/proposals/"]).split(
      separator: "\n"
    ).count == 4)
  #expect(try indexPreservationState(fixture) == before)
  #expect(try git.data(["ls-files", "--stage", "-z"]) == stagedBefore)
  #expect(try fixture.store.render(cwd: fixture.root) == "# Memory\n")
  for (commit, path, replacement) in commits {
    #expect(try fixture.git(["rev-parse", "\(commit)^1"]) == base)
    #expect(try git.data(["cat-file", "blob", "\(commit):\(path)"]) == replacement)
    #expect(
      try git.data(["diff-tree", "-r", "--name-only", "-z", base, commit])
        == Data((path + "\0").utf8))
  }
}
