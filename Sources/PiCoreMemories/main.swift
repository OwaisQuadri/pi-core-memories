import CoreMemories
import Foundation

struct UsageError: Error, CustomStringConvertible {
  let description: String
}

func execute() throws -> Int32 {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else {
    throw UsageError(
      description: "expected init, project-key, render, check, propose, review, or dream-scan")
  }
  if ["dream", "draft", "scope", "setup-device", "bind-project"].contains(command) {
    return try executeClientCommand(arguments)
  }
  if command == "dream-worker" { return executeDreamWorker(arguments: arguments) }
  if command == "memory-review-worker" { return executeMemoryReviewWorker(arguments: arguments) }
  if command == "memory-prepare-worker" {
    return try executeMemoryPrepareWorker(arguments: arguments)
  }
  var options: [String: String] = [:]
  var positional: [String] = []
  var index = 1
  while index < arguments.count {
    let argument = arguments[index]
    if argument.hasPrefix("--") {
      guard index + 1 < arguments.count, options[argument] == nil else {
        throw UsageError(description: "missing value or duplicate option: \(argument)")
      }
      options[argument] = arguments[index + 1]
      index += 2
    } else {
      positional.append(argument)
      index += 1
    }
  }
  let permitted: [String: Set<String>] = [
    "init": ["--repo"], "project-key": ["--cwd", "--config", "--bindings"],
    "render": ["--repo", "--cwd", "--device-key", "--bindings", "--config"],
    "check": ["--repo"], "propose": ["--repo", "--base", "--file", "--reason", "--contradictions"],
    "review": ["--repo"], "manage": ["--repo"], "review-catalog": ["--repo", "--cwd", "--config"],
    "dream-scan": ["--sessions", "--since", "--snippets", "--prompts", "--samples"],
  ]
  guard let allowed = permitted[command], Set(options.keys).isSubset(of: allowed),
    positional.count == (command == "review" ? 1 : 0)
  else { throw UsageError(description: "unknown command, option, or unexpected argument") }

  func required(_ name: String) throws -> String {
    guard let value = options[name], !value.isEmpty else {
      throw UsageError(description: "missing \(name)")
    }
    return value
  }

  func url(_ name: String) throws -> URL {
    URL(fileURLWithPath: try required(name))
  }

  func output(_ text: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
  }

  func scopeConfiguration() throws -> MemoryScopeConfiguration {
    let config = try MemoryConfiguration.load(
      from: options["--config"].map { URL(fileURLWithPath: $0) } ?? MemoryConfiguration.defaultURL)
    var bindings = config.projectBindings
    if let path = options["--bindings"] {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      let bytes = try handle.read(upToCount: 65_537) ?? Data()
      guard bytes.count <= 65_536 else {
        throw UsageError(description: "project bindings too large")
      }
      bindings = try JSONDecoder().decode([String: String].self, from: bytes)
    }
    let scope = MemoryScopeConfiguration(
      deviceKey: options["--device-key"] ?? config.deviceKey, projectBindings: bindings)
    try MemoryScopeConfiguration.validate(
      deviceKey: scope.deviceKey, projectBindings: scope.projectBindings)
    return scope
  }

  switch command {
  case "init":
    try MemoryStore.initialize(repo: url("--repo"))
  case "project-key":
    if let key = try MemoryStore.projectKey(
      cwd: url("--cwd"), projectBindings: scopeConfiguration().projectBindings)
    {
      try output("\(key)\n")
    } else {
      throw UsageError(description: "no project key exists outside a Git repository")
    }
  case "render":
    let scope = try scopeConfiguration()
    try output(
      MemoryStore(repo: url("--repo")).render(
        cwd: url("--cwd"), deviceKey: scope.deviceKey, projectBindings: scope.projectBindings))
  case "check":
    let failures = try MemoryStore(repo: url("--repo")).check()
    if !failures.isEmpty {
      try FileHandle.standardError.write(
        contentsOf: Data((failures.joined(separator: "\n") + "\n").utf8))
      return 1
    }
  case "propose":
    let store = try MemoryStore(repo: url("--repo"))
    let base = try required("--base")
    let path = try required("--file")
    let reason = try required("--reason")
    let replacement = try FileHandle.standardInput.readToEnd() ?? Data()
    let proposal = try store.propose(
      base: base, path: path, replacement: replacement, reason: reason,
      contradictions: options["--contradictions"] ?? "")
    try output("ref: \(proposal.ref)\ncommit: \(proposal.commit)\nbase: \(proposal.base)\n")
  case "review":
    try output(MemoryStore(repo: url("--repo")).review(commit: positional[0]))
  case "review-catalog":
    let scope = try scopeConfiguration()
    let catalog = try MemoryManagement(repository: url("--repo")).reviewCatalog(
      cwd: url("--cwd"),
      deviceKey: scope.deviceKey, projectBindings: scope.projectBindings)
    let bytes = try JSONEncoder().encode(catalog)
    let object = try JSONSerialization.jsonObject(with: bytes)
    let due = catalog.entries.indices.filter {
      MemoryManagement.isReviewDue(catalog.entries[$0].reviewed, date: Date())
    }
    let result = try JSONSerialization.data(withJSONObject: ["catalog": object, "due": due])
    try output(String(decoding: result, as: UTF8.self) + "\n")
  case "manage":
    var bytes = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
      bytes.append(chunk)
      guard bytes.count <= 1_048_576 else {
        throw UsageError(description: "management request too large")
      }
    }
    let request = try MemoryManagementRequest.decode(bytes)
    let result = try MemoryManagement(repository: url("--repo")).execute(request)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try output(String(decoding: try encoder.encode(result), as: UTF8.self) + "\n")
  case "dream-scan":
    let now = Date()
    let since = try options["--since"].map { text in
      guard let date = SessionReader.date(text) else {
        throw UsageError(description: "--since must be an ISO 8601 date")
      }
      return date
    }
    guard let samples = Int(options["--samples"] ?? "0"), samples >= 0 else {
      throw UsageError(description: "--samples must be a nonnegative integer")
    }
    let reader = try SessionReader(
      sessions: url("--sessions"), snippets: options["--snippets"].map { URL(fileURLWithPath: $0) },
      prompts: options["--prompts"].map { URL(fileURLWithPath: $0) })
    let floor = since ?? now.addingTimeInterval(-SessionReader.dreamWindow)
    let window = EntryWindow(filesModifiedAfter: floor, entryFloor: floor, upper: now)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let census = try reader.scan(window: window, sampleLimit: samples).census
    try output(String(decoding: try encoder.encode(census), as: UTF8.self) + "\n")
  default:
    throw UsageError(description: "unknown command")
  }
  return 0
}

do {
  exit(try execute())
} catch {
  let arguments = Array(CommandLine.arguments.dropFirst())
  let repoIndex = arguments.firstIndex(of: "--repo")
  let path =
    repoIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "pi-core-memories"
  let reason = String(describing: error).replacingOccurrences(of: "\n", with: "; ")
  let display = MemoryStore.safeReviewDisplay("FAIL \(path): \(reason)\n")
  try? FileHandle.standardError.write(contentsOf: Data(display.utf8))
  exit(1)
}
