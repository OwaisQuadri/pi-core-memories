import Foundation
import Testing

@testable import CoreMemories

@Test func executableDreamWorkerDispatchRejectsArgumentsWithoutStoreParserDiagnostics() throws {
  let worker = try DreamWorkerProcess(arguments: ["dream-worker", "--repo", "private-source-body"])
  defer { worker.clean() }
  try worker.finish(status: 1, isErrorExpected: true)
}

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

@Test func executableConcurrentProposals() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let base = try fixture.store.approvedCommit()
  let before = try fixture.humanState()
  let outputs = try await withThrowingTaskGroup(of: String.self) { group in
    for index in 0..<6 {
      group.addTask {
        let text = index < 3 ? "Same CLI candidate" : "CLI candidate \(index)"
        let result = try fixture.cli(
          [
            "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md",
            "--reason", "concurrent CLI",
          ], input: Data(fact(text).utf8))
        try #require(result.status == 0, "\(result.errorText)")
        return result.text
      }
    }
    var outputs: [String] = []
    for try await output in group { outputs.append(output) }
    return outputs
  }
  #expect(Set(outputs).count == 4)
  #expect(
    try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/proposals/"])
      .split(separator: "\n").count == 4)
  #expect(try fixture.humanState() == before)
}

@Test func executableCheckReportsAllFailuresOnStderr() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try fixture.write("No metadata", path: "MEMORY.md")
  let key = String(repeating: "b", count: 64)
  try fixture.write("Bad [source: ; added: 2026-02-30]", path: "projects/\(key).md")
  try fixture.commit()
  let checked = try fixture.cli(["check", "--repo", fixture.repo.path])
  #expect(checked.status != 0 && checked.output.isEmpty)
  #expect(checked.errorText.contains("FAIL MEMORY.md:"))
  #expect(checked.errorText.contains("FAIL projects/\(key).md:"))
  _ = try fixture.git(["update-ref", "-d", "refs/heads/main"])
  for command in ["render", "check"] {
    let arguments =
      [command, "--repo", fixture.repo.path]
      + (command == "render" ? ["--cwd", fixture.root.path] : [])
    let result = try fixture.cli(arguments)
    #expect(result.status != 0 && result.output.isEmpty && result.errorText.hasPrefix("FAIL "))
  }
}

@Test func executableDreamScanPrintsCensus() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let store = try DreamStore()
  defer { store.clean() }
  let before = try store.snapshot()
  let arguments = [
    "dream-scan", "--sessions", store.sessions.path, "--snippets", store.snippets.path,
    "--since", "2026-01-10T00:00:00Z", "--samples", "1",
  ]
  let result = try fixture.cli(arguments)
  #expect(result.status == 0 && result.error.isEmpty, "\(result.errorText)")
  #expect(try store.snapshot() == before)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let census = try decoder.decode(Census.self, from: result.output)
  #expect(census.files == 7)
  #expect(census.sessions == [.primary: 1, .child: 3, .infrastructure: 2, .unreadable: 1])
  #expect(census.counts.human[.typed] == 4)
  #expect(
    census.samples == [
      .typed: ["Please make the reader skip snippets."],
      .typedSkillArguments: ["fix the failing census"], .answered: ["yes please"],
      .picked: ["A; B"],
    ])
  #expect(census.window.entryFloor == Date(timeIntervalSince1970: 1_768_003_200))
  #expect(result.text.contains(#""primary" : 1"#))
  let fractional = try fixture.cli(
    ["dream-scan", "--sessions", store.sessions.path, "--since", "2026-01-10T00:00:00.000Z"])
  #expect(fractional.status == 0)
  #expect(try decoder.decode(Census.self, from: fractional.output).samples.isEmpty)
  for invalid in [
    ["dream-scan"], ["dream-scan", "--sessions", store.root.appendingPathComponent("none").path],
    ["dream-scan", "--sessions", store.sessions.path, "--since", "yesterday"],
    ["dream-scan", "--sessions", store.sessions.path, "--samples", "-1"],
    ["dream-scan", "--sessions", store.sessions.path, "--repo", fixture.repo.path],
    ["dream-scan", "--sessions", store.sessions.path, "extra"],
    ["dream-scan", "--sessions", store.sessions.path, "--snippets", store.sessions.path],
    ["dream-scan", "--sessions", store.sessions.path, "--prompts", store.sessions.path],
  ] {
    let refused = try fixture.cli(invalid)
    #expect(refused.status != 0 && refused.output.isEmpty && refused.errorText.hasPrefix("FAIL "))
  }
  #expect(try store.snapshot() == before)
}

@Test func hostileGitEnvironmentCannotRedirectExecutableOperations() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let other = try fixture.project("hostile-source")
  try fixture.write("Staged source edit", path: "human.txt", at: other)
  _ = try fixture.git(["add", "human.txt"], at: other)
  try fixture.write("Unstaged source edit", path: "human.txt", at: other)
  let otherBefore = try fixture.snapshot(other)
  let environment = hostileEnvironment(other: other)
  let before = try fixture.humanState()
  let base = try fixture.store.approvedCommit()
  let render = try fixture.cli(
    ["render", "--repo", fixture.repo.path, "--cwd", fixture.root.path], environment: environment)
  #expect(render.status == 0 && render.text == "# Memory\n")
  #expect(
    try fixture.cli(["check", "--repo", fixture.repo.path], environment: environment).status == 0)
  #expect(
    try fixture.cli(["project-key", "--cwd", fixture.root.path], environment: environment).status
      != 0)
  let key = try fixture.cli(["project-key", "--cwd", fixture.repo.path], environment: environment)
  let expectedKey = try #require(try MemoryStore.projectKey(cwd: fixture.repo))
  #expect(key.status == 0 && key.text == expectedKey + "\n")
  let arguments = [
    "propose", "--repo", fixture.repo.path, "--base", base, "--file", "MEMORY.md", "--reason",
    "hostile safe",
  ]
  let result = try fixture.cli(
    arguments, input: Data(fact("Executable safe").utf8), environment: environment)
  #expect(result.status == 0 && result.error.isEmpty)
  let commitLine = try #require(
    result.text.split(separator: "\n").first(where: { $0.hasPrefix("commit: ") }))
  let commit = String(commitLine.dropFirst(8))
  #expect(
    try fixture.cli(["review", "--repo", fixture.repo.path, commit], environment: environment)
      .status == 0)
  let fresh = fixture.root.appendingPathComponent("fresh-cli")
  #expect(try fixture.cli(["init", "--repo", fresh.path], environment: environment).status == 0)
  #expect(
    try fixture.cli(
      ["init", "--repo", other.appendingPathComponent("nested").path], environment: environment
    ).status != 0)
  #expect(try fixture.humanState() == before)
  #expect(try fixture.snapshot(other) == otherBefore)
}
