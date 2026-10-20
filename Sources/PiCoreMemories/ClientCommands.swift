import CoreMemories
import Darwin
import Foundation

func executeClientCommand(_ arguments: [String]) throws -> Int32 {
  let command = arguments[0]
  var options: [String: String] = [:]
  let operation: String
  let start: Int
  if command == "dream" || command == "draft" {
    guard arguments.count > 1 else {
      throw UsageError(description: "expected \(command) operation")
    }
    operation = arguments[1]
    start = 2
  } else {
    operation = command
    start = 1
  }
  let isPromptRelocation =
    command == "dream"
    && ["relocate-prompts-preview", "relocate-prompts-confirm"].contains(operation)
  var index = start
  while index < arguments.count {
    guard arguments[index].hasPrefix("--"), index + 1 < arguments.count,
      options[arguments[index]] == nil
    else { throw UsageError(description: "invalid command option") }
    options[arguments[index]] = arguments[index + 1]
    index += 2
  }
  let allowed: Set<String>
  switch command {
  case "dream":
    switch operation {
    case "relocate-prompts-preview": allowed = ["--config", "--baseline-run", "--to"]
    case "relocate-prompts-confirm":
      allowed = ["--config", "--baseline-run", "--to", "--preview", "--confirm"]
    default: allowed = ["--config", "--state"]
    }
  case "draft": allowed = ["--config", "--repo", "--journal", "--id", "--revision", "--key"]
  case "scope", "setup-device": allowed = ["--config"]
  case "bind-project": allowed = ["--config", "--cwd", "--key"]
  default: throw UsageError(description: "unknown client command")
  }
  guard Set(options.keys).isSubset(of: allowed) else {
    throw UsageError(description: "unknown option")
  }
  let configURL =
    options["--config"].map { URL(fileURLWithPath: $0) } ?? MemoryConfiguration.defaultURL
  var config: MemoryConfiguration
  if command == "setup-device" || command == "bind-project",
    !FileManager.default.fileExists(atPath: configURL.path)
  {
    config = .defaults
  } else {
    config = try MemoryConfiguration.load(from: configURL)
  }
  func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(value)
    if isPromptRelocation {
      guard bytes.count <= 8_388_608 else { throw DreamRunError.limitExceeded }
    }
    try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
  }
  if command == "scope" {
    let data = try JSONSerialization.data(
      withJSONObject: [
        "deviceKey": config.deviceKey as Any? ?? NSNull(),
        "projectBindings": config.projectBindings,
      ], options: [.sortedKeys])
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    return 0
  }
  if command == "setup-device" {
    config.setupDevice()
    try config.save(to: configURL)
    try output(config.deviceKey)
    return 0
  }
  if command == "bind-project" {
    guard let cwd = options["--cwd"], let key = options["--key"],
      let common = try MemoryStore.projectBindingDirectory(cwd: URL(fileURLWithPath: cwd))
    else {
      throw UsageError(description: "bind-project requires --cwd and --key in a Git repository")
    }
    config.projectBindings[common] = key
    try config.save(to: configURL)
    try output(
      MemoryScopeConfiguration(deviceKey: config.deviceKey, projectBindings: config.projectBindings)
    )
    return 0
  }
  if command == "dream" {
    if isPromptRelocation {
      guard let baseline = options["--baseline-run"], let target = options["--to"],
        target.hasPrefix("/"),
        operation != "relocate-prompts-confirm"
          || (options["--confirm"] == "yes" && options["--preview"] != nil)
      else {
        throw UsageError(
          description:
            "prompt relocation requires --baseline-run and canonical --to; confirmation also requires --preview and --confirm yes"
        )
      }
      let sources = try config.reviewSources(
        stateRoot: config.stateURL,
        memoryRepository: config.memoryURL, isReadOnly: true)
      let historical = try sources.historicalSourceIdentities
      let roles = try config.queueSourceRoles(
        sessions: historical.sessions, stripping: historical.stripping)
      if operation == "relocate-prompts-preview" {
        try output(
          sources.previewPromptRelocation(
            baselineRunID: baseline,
            replacement: URL(fileURLWithPath: target), sourceRoles: roles))
      } else {
        try output(
          sources.confirmPromptRelocation(
            baselineRunID: baseline,
            replacement: URL(fileURLWithPath: target), sourceRoles: roles,
            expectedPreviewHash: options["--preview"]!, authorization: .explicitCaller))
      }
      return 0
    }
    if operation == "inspect" {
      try output(
        DreamInspection.read(
          stateRoot: options["--state"].map { URL(fileURLWithPath: $0) } ?? config.stateURL))
      return 0
    }
    guard let action = DreamControlOperation(rawValue: operation), options["--state"] == nil else {
      throw UsageError(
        description:
          "expected dream inspect, start, all, retry, or replace; Ctrl+C cancels only this invocation"
      )
    }
    let control = DreamControl()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interrupt.setEventHandler { control.cancel() }
    terminate.setEventHandler { control.cancel() }
    interrupt.resume()
    terminate.resume()
    defer {
      interrupt.cancel()
      terminate.cancel()
    }
    try control.run(
      operation: action, settings: config.settings, roots: config.roots,
      diagnostics: URL(fileURLWithPath: config.diagnostics), deviceKey: config.deviceKey,
      projectBindings: config.projectBindings,
      onEvent: { bytes in
        try? FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
      })
    return 0
  }
  let store = try MemoryDraftStore(
    repository: options["--repo"].map { URL(fileURLWithPath: $0) } ?? config.memoryURL,
    journal: URL(fileURLWithPath: options["--journal"] ?? config.journal))
  if operation == "list" {
    try output(store.list())
    return 0
  }
  if operation == "create" {
    try output(store.create())
    return 0
  }
  guard let rawID = options["--id"], let id = UUID(uuidString: rawID),
    let rawRevision = options["--revision"], let revision = UInt64(rawRevision)
  else { throw UsageError(description: "draft operation requires --id and --revision") }
  switch operation {
  case "get":
    guard let draft = try store.list().first(where: { $0.draftID == id && $0.revision == revision })
    else {
      throw UsageError(description: "draft not found at requested revision")
    }
    try output(draft)
  case "update":
    let bytes = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
    guard bytes.count <= 1_048_576,
      let array = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
    else {
      throw UsageError(description: "expected bounded array of exact CRUD requests")
    }
    let requests = try array.map {
      try MemoryManagementRequest.decode(JSONSerialization.data(withJSONObject: $0))
    }
    try output(store.update(draftID: id, expectedRevision: revision, operations: requests))
  case "save":
    guard let key = options["--key"] else { throw UsageError(description: "Save requires --key") }
    try output(store.save(draftID: id, expectedRevision: revision, idempotencyKey: key))
  case "discard":
    try store.discard(draftID: id, expectedRevision: revision)
    try output(["discarded": rawID])
  default:
    throw UsageError(description: "expected draft list, create, get, update, save, or discard")
  }
  return 0
}
