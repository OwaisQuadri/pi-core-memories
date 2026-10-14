import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [nil, "0", "1"] as [String?])
func missingApprovedBlobNeverFetches(noFetchValue: String?) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let human = fixture.root.appendingPathComponent("human.txt")
  let invoked = fixture.root.appendingPathComponent("transport-invoked")
  let transport = fixture.root.appendingPathComponent("remote-command")
  try fixture.write("original", path: "human.txt", at: fixture.root)
  try fixture.write(
    """
    #!/bin/zsh
    print -rn -- invoked >> "\(invoked.path)"
    print -rn -- overwritten > "\(human.path)"
    exit 1
    """, path: "remote-command", at: fixture.root)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transport.path)
  for setting in [
    ["extensions.partialClone", "origin"], ["remote.origin.promisor", "true"],
    ["remote.origin.url", "ext::\(transport.path)"], ["protocol.ext.allow", "always"],
  ] {
    _ = try fixture.git(["config"] + setting)
  }
  var environment = ProcessInfo.processInfo.environment
  environment["GIT_NO_LAZY_FETCH"] = noFetchValue
  let store = try MemoryStore(repo: fixture.repo, environment: environment)
  #expect(try store.render(cwd: fixture.root) == "# Memory\n")
  #expect(try store.check().isEmpty)
  let base = try store.approvedCommit()
  let proposal = try store.propose(
    base: base, path: "MEMORY.md", replacement: Data(fact("Complete local candidate").utf8),
    reason: "Complete partial store")
  #expect(try store.review(commit: proposal.commit).contains("Complete local candidate"))
  #expect(try store.render(cwd: fixture.root) == "# Memory\n")
  let binary = try #require(environment["PI_CORE_MEMORIES_BIN"])
  for command in ["render", "check"] {
    let arguments =
      [command, "--repo", fixture.repo.path]
      + (command == "render" ? ["--cwd", fixture.root.path] : [])
    let result = try runCommand(
      executable: URL(fileURLWithPath: binary), arguments: arguments, environment: environment)
    #expect(result.status == 0 && result.error.isEmpty)
    #expect(result.text == (command == "render" ? "# Memory\n" : ""))
  }
  let blob = try fixture.git(["rev-parse", "refs/heads/main:MEMORY.md"])
  let object = fixture.repo.appendingPathComponent(
    ".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))")
  try FileManager.default.removeItem(at: object)
  let before = try fixture.snapshot(fixture.root)
  #expect(throws: (any Error).self) { try store.render(cwd: fixture.root) }
  #expect(throws: (any Error).self) { try store.check() }
  #expect(try fixture.snapshot(fixture.root) == before)
  for command in ["render", "check"] {
    let arguments =
      [command, "--repo", fixture.repo.path]
      + (command == "render" ? ["--cwd", fixture.root.path] : [])
    let result = try runCommand(
      executable: URL(fileURLWithPath: binary), arguments: arguments, environment: environment)
    #expect(result.status != 0 && result.output.isEmpty)
    #expect(result.errorText.hasPrefix("FAIL "))
    #expect(!result.errorText.contains("remote repository"))
    #expect(try fixture.snapshot(fixture.root) == before)
  }
  #expect(try Data(contentsOf: human) == Data("original".utf8))
  #expect(!FileManager.default.fileExists(atPath: invoked.path))
  #expect(!FileManager.default.fileExists(atPath: object.path))
}

@Test func checkEscapesFilenamesAndKeepsBodyFailuresReadable() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let controls =
    Array(1...8) + Array(11...31) + Array(127...159)
    + [0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x206F)
  let rawControls = controls.map { String(Unicode.Scalar($0)!) }.joined()
  let path = "z-\u{1B}[2J\u{1B}[HAPPROVED\u{1B}[8m-café-🐢-" + rawControls
  let valid = fact("Body \u{1B}[2J\u{1B}[8mhidden\u{1B}[0m café العربية 👩🏽‍💻 🐢\tstill here")
  try fixture.write(valid, path: "MEMORY.md")
  try fixture.commit()
  let validBefore = try fixture.snapshot(fixture.root)
  #expect(try fixture.store.check().isEmpty)
  #expect(try fixture.store.render(cwd: fixture.root) == valid)
  let validRender = try fixture.cli([
    "render", "--repo", fixture.repo.path, "--cwd", fixture.root.path,
  ])
  #expect(validRender.status == 0 && validRender.output == Data(valid.utf8))
  #expect(try fixture.cli(["check", "--repo", fixture.repo.path]).error.isEmpty)
  #expect(try fixture.snapshot(fixture.root) == validBefore)
  try fixture.write("Unannotated \u{1B}[8mhidden\n", path: "MEMORY.md")
  let key = String(repeating: "a", count: 64)
  try fixture.write(
    "Body \u{1B}[8mhidden [source: own\u{1B}er; added: 2024-02-29]\n",
    path: "projects/\(key).md")
  try fixture.write("human bytes", path: path)
  try fixture.commit()
  let before = try fixture.snapshot(fixture.root)
  let failures = try fixture.store.check()
  #expect(failures.count == 3)
  #expect(
    failures.contains(
      "FAIL MEMORY.md: line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"))
  #expect(
    failures.contains(
      "FAIL projects/\(key).md: line 1: source reference must be nonempty and contain no controls"))
  let display = failures.joined(separator: "\n")
  #expect(display.contains("FAIL z-\\u{1B}[2J\\u{1B}[HAPPROVED\\u{1B}[8m-café-🐢-"))
  #expect(display.contains(": path is not an allowed memory file"))
  #expect(!display.unicodeScalars.contains { controls.contains(Int($0.value)) })
  #expect(
    controls.allSatisfy { display.contains("\\u{\(String($0, radix: 16, uppercase: true))}") })
  let checked = try fixture.cli(["check", "--repo", fixture.repo.path])
  #expect(checked.status != 0 && checked.output.isEmpty)
  #expect(checked.errorText == display + "\n")
  let rendered = try fixture.cli([
    "render", "--repo", fixture.repo.path, "--cwd", fixture.root.path,
  ])
  #expect(rendered.status != 0 && rendered.output.isEmpty)
  #expect(rendered.errorText.contains("FAIL "))
  #expect(!rendered.error.contains(0x1B))
  #expect(try fixture.snapshot(fixture.root) == before)
}

@Test func executableEscapesRepositoryPathsAndUsageErrors() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let path = fixture.root.appendingPathComponent("missing-\u{1B}[2J\u{1B}[H\u{1B}[8m-café-🐢")
  let before = try fixture.snapshot(fixture.root)
  let result = try fixture.cli(["check", "--repo", path.path])
  #expect(result.status != 0 && result.output.isEmpty)
  #expect(
    result.errorText
      == "FAIL \(fixture.root.path)/missing-\\u{1B}[2J\\u{1B}[H\\u{1B}[8m-café-🐢: directory does not exist\n"
  )
  #expect(!result.error.contains(0x1B))
  #expect(!FileManager.default.fileExists(atPath: path.path))
  let usage = try fixture.cli([
    "check", "--repo", fixture.repo.path, "--\u{1B}[2J\u{D}\u{202E}café-🐢",
  ])
  #expect(usage.status != 0 && usage.output.isEmpty)
  #expect(
    usage.errorText
      == "FAIL \(fixture.repo.path): missing value or duplicate option: --\\u{1B}[2J\\u{D}\\u{202E}café-🐢\n"
  )
  #expect(!usage.errorText.unicodeScalars.contains { [0x1B, 0xD, 0x202E].contains($0.value) })
  #expect(try fixture.snapshot(fixture.root) == before)
}

@Test func executableEscapesGitErrorTextWithoutChangingConfig() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let value = "git-\u{9B}2J-café-🐢\u{202E}\u{2066}"
  let config = fixture.root.appendingPathComponent(value)
  try fixture.write("[broken\n", path: value, at: fixture.root)
  _ = try fixture.git(["config", "include.path", config.path])
  let before = try fixture.snapshot(fixture.root)
  let raw = try Git(repo: fixture.repo, environment: ProcessInfo.processInfo.environment).run([
    "rev-parse", "--show-toplevel",
  ])
  #expect(raw.status != 0 && raw.errorText.contains(value))
  for command in ["render", "check"] {
    let arguments =
      [command, "--repo", fixture.repo.path]
      + (command == "render" ? ["--cwd", fixture.root.path] : [])
    let result = try fixture.cli(arguments)
    #expect(result.status != 0 && result.output.isEmpty)
    #expect(result.errorText.contains("bad config line 1 in file"))
    #expect(result.errorText.contains("git-\\u{9B}2J-café-🐢\\u{202E}\\u{2066}"))
    #expect(
      !result.errorText.unicodeScalars.contains { [0x9B, 0x202E, 0x2066].contains($0.value) })
  }
  #expect(try fixture.snapshot(fixture.root) == before)
}

@Test func repeatedCheckDiagnosticsPreserveState() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let paths = (0..<128).map { String(format: "z-%03d-café-🐢", $0) }
  for path in paths { try fixture.write("fixture", path: path) }
  try fixture.commit()
  let before = try fixture.snapshot(fixture.root)
  let expected = paths.map { "FAIL \($0): path is not an allowed memory file\n" }.joined()
  var seconds = 0.0
  for repetition in 0...5 {
    let start = Date.timeIntervalSinceReferenceDate
    let result = try fixture.cli(["check", "--repo", fixture.repo.path])
    let elapsed = Date.timeIntervalSinceReferenceDate - start
    #expect(result.status != 0 && result.output.isEmpty && result.errorText == expected)
    if repetition > 0 { seconds += elapsed }
  }
  #expect(try fixture.snapshot(fixture.root) == before)
  print(
    "DIAGNOSTIC_TIMING files=128 warmup=1 repetitions=5 check_ms=\(seconds * 200)")
}
