import CryptoKit
import Foundation
import Testing

@testable import CoreMemories

struct Fixture {
  let root: URL
  let repo: URL
  let store: MemoryStore

  init() throws {
    root = try temporaryDirectory()
    repo = root.appendingPathComponent("memory store")
    try MemoryStore.initialize(repo: repo)
    store = try MemoryStore(repo: repo)
  }

  func clean() {
    try? FileManager.default.removeItem(at: root)
  }

  func git(_ arguments: [String], at directory: URL? = nil, input: Data = Data()) throws -> String {
    try Git(repo: directory ?? repo, environment: ProcessInfo.processInfo.environment).text(
      arguments, input: input, additions: Git.proposalIdentity)
  }

  func write(_ text: String, path: String, at directory: URL? = nil) throws {
    let url = (directory ?? repo).appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func commit() throws {
    _ = try git(["add", "."])
    _ = try git(["commit", "-m", "Human fixture approval"])
  }

  func project(_ name: String) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    _ = try git(["init", "--initial-branch=main", "--template="], at: directory)
    _ = try git(["commit", "--allow-empty", "-m", "Project fixture"], at: directory)
    return directory
  }

  func cli(_ arguments: [String], input: Data = Data(), environment: [String: String] = [:]) throws
    -> CommandResult
  {
    let path = try #require(
      ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_BIN"]
        ?? ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_EXECUTABLE"])
    #expect(FileManager.default.isExecutableFile(atPath: path))
    return try runCommand(
      executable: URL(fileURLWithPath: path), arguments: arguments,
      environment: ProcessInfo.processInfo.environment.merging(environment) { _, new in new },
      input: input)
  }

  func snapshot(_ directory: URL) throws -> [String: Data] {
    let enumerator = try #require(
      FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    )
    var files: [String: Data] = [:]
    for case let file as URL in enumerator {
      if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        let rootPath = directory.resolvingSymlinksInPath().path
        let filePath = file.resolvingSymlinksInPath().path
        try #require(filePath.hasPrefix(rootPath + "/"))
        files[String(filePath.dropFirst(rootPath.count + 1))] = try Data(contentsOf: file)
      }
    }
    return files
  }

  func humanState() throws -> [String: Data] {
    var state = try snapshot(repo).filter { !$0.key.hasPrefix(".git/") }
    for path in [".git/index", ".git/HEAD"] {
      let url = repo.appendingPathComponent(path)
      if FileManager.default.fileExists(atPath: url.path) {
        state[path] = try Data(contentsOf: url)
      }
    }
    state["main"] = Data(try store.approvedCommit().utf8)
    state["status"] = Data(try git(["status", "--porcelain=v1", "--untracked-files=all"]).utf8)
    return state
  }
}

func fact(_ text: String) -> String {
  "\(text) [source: docs/owner.md#rule; added: 2024-02-29]\n"
}

@Test func documentValidation() {
  let valid = """
    # Memory

    An owner holds this rule, with a multiline
    paragraph and a [reference][owner].
    [source: docs/owner.md#rule; added: 2024-02-29]

    - First fact [source: session:primary/role=user; added: 2000-02-29]
    - Second fact
      continues here [source: https://example.test/source; added: 2026-08-01]

    [owner]: docs/owner.md
    """
  #expect(MemoryDocument.failures(in: Data(valid.utf8)).isEmpty)
  #expect(MemoryDocument.failures(in: Data("# Memory\n".utf8)).isEmpty)
  #expect(MemoryDocument.failures(in: Data("Memory\n======\n".utf8)).isEmpty)
  let multiple =
    fact("Unicode 🐢") + fact("Two annotations").trimmingCharacters(in: .newlines)
    + " [source: owner; added: 2026-01-01]\n"
  #expect(MemoryDocument.failures(in: Data(multiple.utf8)).isEmpty)
  for invalid in [
    "Unannotated fact", "Fact [source: ; added: 2026-01-01]",
    "Fact [source:   ; added: 2026-01-01]", "Fact [source: owner]",
    "Fact [added: 2026-01-01]", "Fact [source: owner; added: 2026-02-29]",
    "Fact [source: owner; added: 1900-02-29]", "Fact [source: owner; added: 2026-04-31]",
    "Fact [source: owner; added: 0000-01-01]", "Fact [source: owner; added: 2026-13-01]",
    "Fact [source: owner; added: 2026-01-00]", "Fact [source: owner; added: 26-01-01]",
    "Fact [source: owner; added: 2026-01-01", "Fact [source: [nested]; added: 2026-01-01]",
    fact("Valid") + "\nMissing annotation", fact("Valid") + "Bad [source: broken]",
    "# Heading [source: ; added: 2026-01-01]", "Fact [source: own\ter; added: 2026-01-01]",
  ] {
    #expect(!MemoryDocument.failures(in: Data(invalid.utf8)).isEmpty, "\(invalid)")
  }
  #expect(!MemoryDocument.failures(in: Data([0xff])).isEmpty)
  #expect(!MemoryDocument.failures(in: Data("\0".utf8)).isEmpty)
}

@Test func pathValidation() {
  #expect(MemoryDocument.isAllowedPath("MEMORY.md"))
  #expect(MemoryDocument.isAllowedPath("projects/\(String(repeating: "a", count: 64)).md"))
  for path in [
    "../MEMORY.md", "/MEMORY.md", ".git/config", "projects/../MEMORY.md", "./MEMORY.md",
    "projects/key.md", "projects/\(String(repeating: "A", count: 64)).md",
    "projects/\(String(repeating: "a", count: 64)).md\n", "MEMORY.md\0", "projects//key.md",
  ] {
    #expect(!MemoryDocument.isAllowedPath(path))
  }
}

@Test func initializationRefusesHumanData() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  #expect(try fixture.store.render(cwd: fixture.root) == "# Memory\n")
  #expect(try fixture.git(["symbolic-ref", "HEAD"]) == "refs/heads/main")
  let occupied = fixture.root.appendingPathComponent("occupied")
  try fixture.write("human", path: "keep", at: occupied)
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: occupied) }
  #expect(try Data(contentsOf: occupied.appendingPathComponent("keep")) == Data("human".utf8))
  let symlink = fixture.root.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: occupied)
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: symlink) }
  let dangling = fixture.root.appendingPathComponent("dangling")
  try FileManager.default.createSymbolicLink(
    at: dangling, withDestinationURL: fixture.root.appendingPathComponent("absent"))
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: dangling) }
  let nested = fixture.repo.appendingPathComponent("nested")
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: nested) }
  #expect(!FileManager.default.fileExists(atPath: nested.path))
  let existingEmpty = fixture.root.appendingPathComponent("empty")
  try FileManager.default.createDirectory(at: existingEmpty, withIntermediateDirectories: false)
  try MemoryStore.initialize(repo: existingEmpty)
  #expect(try MemoryStore(repo: existingEmpty).check().isEmpty)
  let before = try fixture.snapshot(fixture.repo)
  #expect(throws: (any Error).self) { try MemoryStore.initialize(repo: fixture.repo) }
  #expect(try fixture.snapshot(fixture.repo) == before)
}

@Test func renderingUsesMainAndProjectCommonDirectory() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let project = try fixture.project("project")
  let worktreeOne = fixture.root.appendingPathComponent("linked-one")
  let worktreeTwo = fixture.root.appendingPathComponent("linked-two")
  _ = try fixture.git(["worktree", "add", "-b", "one", worktreeOne.path], at: project)
  _ = try fixture.git(["worktree", "add", "-b", "two", worktreeTwo.path], at: project)
  let key = try #require(try MemoryStore.projectKey(cwd: project))
  let common = try fixture.git(
    ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: project)
  let canonical = common
  #expect(
    key == SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined())
  #expect(try MemoryStore.projectKey(cwd: worktreeOne) == key)
  #expect(try MemoryStore.projectKey(cwd: worktreeTwo) == key)
  let alias = fixture.root.appendingPathComponent("project-alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
  #expect(try MemoryStore.projectKey(cwd: alias) == key)
  let unrelated = try fixture.project("unrelated")
  let otherKey = try #require(try MemoryStore.projectKey(cwd: unrelated))
  try fixture.write(fact("Approved global"), path: "MEMORY.md")
  try fixture.write(fact("Approved project"), path: "projects/\(key).md")
  try fixture.write(fact("Unrelated secret"), path: "projects/\(otherKey).md")
  try fixture.commit()
  let base = try fixture.store.approvedCommit()
  let proposal = try fixture.store.propose(
    base: base, path: "MEMORY.md", replacement: Data(fact("Proposed global").utf8),
    reason: "candidate")
  _ = try fixture.git(["switch", "--detach", proposal.commit])
  try fixture.write("Dirty global", path: "MEMORY.md")
  try fixture.write("Dirty project", path: "projects/\(key).md")
  let rendered = try fixture.store.render(cwd: worktreeTwo)
  #expect(rendered == fact("Approved global") + "\n" + fact("Approved project"))
  #expect(!rendered.contains("Unrelated"))
  #expect(try fixture.store.render(cwd: fixture.root) == fact("Approved global"))
  #expect(try fixture.store.check().isEmpty)
}

@Test func checkValidatesEveryApprovedFile() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let key = String(repeating: "a", count: 64)
  let symlinkKey = String(repeating: "b", count: 64)
  try fixture.write("Unannotated", path: "projects/\(key).md")
  try fixture.write(fact("Invalid path"), path: "projects/not-a-key.md")
  try FileManager.default.createSymbolicLink(
    at: fixture.repo.appendingPathComponent("projects/\(symlinkKey).md"),
    withDestinationURL: fixture.repo.appendingPathComponent("MEMORY.md"))
  try fixture.commit()
  let failures = try fixture.store.check()
  #expect(failures.contains(where: { $0.hasPrefix("FAIL projects/\(key).md:") }))
  #expect(failures.contains("FAIL projects/not-a-key.md: path is not an allowed memory file"))
  #expect(failures.contains("FAIL projects/\(symlinkKey).md: memory must be a regular file"))
  #expect(try fixture.store.render(cwd: fixture.root) == "# Memory\n")
}
