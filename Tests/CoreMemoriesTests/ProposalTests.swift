import Foundation
import Testing

@testable import CoreMemories

@Test func proposalsPreserveHumanFilesAndReviewExactDiff() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  try fixture.write("Staged human memory", path: "MEMORY.md")
  _ = try fixture.git(["add", "MEMORY.md"])
  try fixture.write("Unstaged human memory", path: "MEMORY.md")
  try fixture.write("Untracked human file", path: "human.txt")
  let before = try fixture.humanState()
  let replacement = Data((fact("An approved instruction owner is docs/owner.md 🐢") + "\n\n").utf8)
  let reason = "Explain the owner\nContradictions:\nnot a delimiter\n\"quoted\""
  let contradictions = "Known conflict\nwith an older entry"
  let proposal = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
    contradictions: contradictions)
  let duplicate = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: replacement, reason: reason,
    contradictions: contradictions)
  #expect(proposal.commit == duplicate.commit)
  #expect(proposal.ref == duplicate.ref)
  #expect(proposal.base == base)
  #expect(
    try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/proposals/"])
      == proposal.ref)
  #expect(
    try Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment).data([
      "cat-file", "blob", "\(proposal.commit):MEMORY.md",
    ]) == replacement)
  #expect(try fixture.git(["rev-parse", "\(proposal.commit)^1"]) == base)
  let review = try fixture.store.review(commit: proposal.commit)
  let exactDiff = try Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment)
    .data([
      "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--binary", base,
      proposal.commit, "--",
    ])
  #expect(review.contains(String(decoding: exactDiff, as: UTF8.self)))
  #expect(review.contains("Parent/Base: \(base)"))
  #expect(review.contains("Reason:\n\(reason)\nContradictions:\n\(contradictions)"))
  #expect(review.contains("HUMAN approval only"))
  #expect(review.contains("git merge --ff-only \(proposal.commit)"))
  #expect(review.contains("Never reset or force"))
  #expect(try fixture.humanState() == before)
  #expect(try fixture.store.render(cwd: fixture.root) == "# Memory\n")
  #expect(throws: (any Error).self) { _ = try fixture.store.review(commit: base) }
  #expect(throws: (any Error).self) { _ = try fixture.store.review(commit: "main") }
}

@Test func unsafeAndStaleProposalsAreRejected() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let before = try fixture.snapshot(fixture.repo)
  let replacement = Data(fact("New").utf8)
  for path in [
    "../source/MEMORY.md", ".git/config", ".git/refs/heads/main",
    fixture.repo.appendingPathComponent("MEMORY.md").path, "projects/../MEMORY.md",
  ] {
    #expect(throws: (any Error).self) {
      _ = try fixture.store.propose(
        base: base, path: path, replacement: replacement, reason: "test")
    }
  }
  for document in [
    Data([0xff]), Data("Fact without metadata".utf8),
    Data("Fact [source: ; added: 2026-01-01]".utf8),
  ] {
    #expect(throws: (any Error).self) {
      _ = try fixture.store.propose(
        base: base, path: "MEMORY.md", replacement: document, reason: "test")
    }
  }
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: "main", path: "MEMORY.md", replacement: replacement, reason: "test")
  }
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: " ")
  }
  #expect(try fixture.snapshot(fixture.repo) == before)
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: base, path: "MEMORY.md", replacement: Data("# Memory\n".utf8), reason: "no change")
  }
  try fixture.write(fact("Human update"), path: "MEMORY.md")
  try fixture.commit()
  let updated = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) {
    _ = try fixture.store.propose(
      base: base, path: "MEMORY.md", replacement: replacement, reason: "stale")
  }
  #expect(try fixture.snapshot(fixture.repo) == updated)
}

@Test func newProjectProposalDoesNotCreateWorkingFiles() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let project = try fixture.project("new-project")
  let key = try #require(try MemoryStore.projectKey(cwd: project))
  let path = "projects/\(key).md"
  let before = try fixture.humanState()
  let replacement = Data(
    "Project fact [source: ../../source/.git/config; added: 2026-01-01]\n".utf8)
  let proposal = try fixture.store.propose(
    base: fixture.store.approvedCommit(), path: path, replacement: replacement,
    reason: "new project")
  #expect(
    !FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("projects").path))
  #expect(try fixture.humanState() == before)
  #expect(try fixture.store.render(cwd: project) == "# Memory\n")
  #expect(try fixture.store.review(commit: proposal.commit).contains("new file mode 100644"))
  #expect(
    try Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment).data([
      "cat-file", "blob", "\(proposal.commit):\(path)",
    ]) == replacement)
}

func hostileEnvironment(other: URL) -> [String: String] {
  [
    "GIT_DIR": other.appendingPathComponent(".git").path,
    "GIT_COMMON_DIR": other.appendingPathComponent(".git").path,
    "GIT_WORK_TREE": other.path,
    "GIT_INDEX_FILE": other.appendingPathComponent(".git/index").path,
    "GIT_PREFIX": "misleading/",
  ]
}

@Test func hostileGitEnvironmentCannotRedirectCoreOperations() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let other = try fixture.project("other-source")
  try fixture.write("Human source edits", path: "human.txt", at: other)
  _ = try fixture.git(["add", "human.txt"], at: other)
  let otherBefore = try fixture.snapshot(other)
  let environment = ProcessInfo.processInfo.environment.merging(hostileEnvironment(other: other)) {
    _, new in new
  }
  let store = try MemoryStore(repo: fixture.repo, environment: environment)
  #expect(try store.render(cwd: fixture.root) == "# Memory\n")
  #expect(try store.check().isEmpty)
  #expect(try MemoryStore.projectKey(cwd: fixture.root, environment: environment) == nil)
  #expect(
    try MemoryStore.projectKey(cwd: fixture.repo, environment: environment)
      == MemoryStore.projectKey(cwd: fixture.repo))
  let before = try fixture.humanState()
  let proposal = try store.propose(
    base: store.approvedCommit(), path: "MEMORY.md", replacement: Data(fact("Core safe").utf8),
    reason: "safe")
  #expect(try store.review(commit: proposal.commit).contains("Core safe"))
  let fresh = fixture.root.appendingPathComponent("fresh-core")
  try MemoryStore.initialize(repo: fresh, environment: environment)
  #expect(try MemoryStore(repo: fresh).check().isEmpty)
  #expect(throws: (any Error).self) {
    try MemoryStore.initialize(
      repo: other.appendingPathComponent("nested"), environment: environment)
  }
  #expect(try fixture.humanState() == before)
  #expect(try fixture.snapshot(other) == otherBefore)
}

@Test func concurrentIdenticalAndDifferentProposals() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let before = try fixture.humanState()
  let commits = try await withThrowingTaskGroup(of: String.self) { group in
    for index in 0..<6 {
      group.addTask {
        let text = index < 3 ? "Identical" : "Different \(index)"
        return try fixture.store.propose(
          base: base, path: "MEMORY.md", replacement: Data(fact(text).utf8), reason: "concurrent"
        ).commit
      }
    }
    var commits: [String] = []
    for try await commit in group { commits.append(commit) }
    return commits
  }
  #expect(Set(commits).count == 4)
  #expect(
    try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/proposals/"]).split(
      separator: "\n"
    ).count == 4)
  #expect(try fixture.humanState() == before)
}
