import Darwin
import Foundation
import Testing

@testable import CoreMemories

final class DreamWorkerProcess {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  let error = Pipe()
  private var buffered = Data()
  private let deadline = Date().addingTimeInterval(20)

  init(arguments: [String] = ["dream-worker"]) throws {
    let binary = try #require(ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_BIN"])
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.environment = [
      "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "GIT_TERMINAL_PROMPT": "0",
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    try input.fileHandleForReading.close()
    try output.fileHandleForWriting.close()
    try error.fileHandleForWriting.close()
  }

  func clean() {
    try? input.fileHandleForWriting.close()
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    let limit = Date().addingTimeInterval(3)
    while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
    try? output.fileHandleForReading.close()
    try? error.fileHandleForReading.close()
  }

  func send(_ object: [String: Any], isFragmented: Bool = false) throws {
    let bytes = try workerBytes(object)
    if isFragmented {
      for byte in bytes {
        try input.fileHandleForWriting.write(contentsOf: Data([byte]))
      }
    } else {
      try input.fileHandleForWriting.write(contentsOf: bytes)
    }
  }

  func sendRaw(_ bytes: Data) throws {
    try input.fileHandleForWriting.write(contentsOf: bytes)
  }

  func closeInput() throws { try input.fileHandleForWriting.close() }

  var progressFrames: [[String: Any]] = []

  func frame() throws -> [String: Any] {
    while true {
      if let newline = buffered.firstIndex(of: 10) {
        let bytes = buffered[..<newline]
        buffered.removeSubrange(...newline)
        let frame = try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        if frame["type"] as? String == "progress" {
          progressFrames.append(frame)
          #expect(Set(frame.keys) == ["version", "type", "invocationID", "backlogBytes", "backlogLimitBytes", "plannedBytes", "completedBytes", "undreamtBytes", "nextBytes", "repeatedRecords", "estimateSeconds"])
          continue
        }
        return frame
      }
      guard Date() < deadline else { throw MemoryError("worker output timed out") }
      var descriptor = pollfd(
        fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let count = poll(&descriptor, 1, 100)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw MemoryError("worker poll failed") }
      if count == 0 { continue }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let received = Darwin.read(descriptor.fd, &bytes, bytes.count)
      guard received > 0 else { throw MemoryError("worker output ended before frame") }
      guard buffered.count <= 4_194_304 - received else { throw MemoryError("worker output limit") }
      buffered.append(contentsOf: bytes.prefix(received))
    }
  }

  func finish(status: Int32 = 0, isErrorExpected: Bool = false) throws {
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try #require(!process.isRunning, "worker exit timed out")
    #expect(process.terminationStatus == status)
    let tail = try output.fileHandleForReading.readToEnd() ?? Data()
    #expect(buffered.isEmpty && tail.isEmpty)
    let diagnostic = try error.fileHandleForReading.readToEnd() ?? Data()
    if isErrorExpected {
      #expect(
        String(decoding: diagnostic, as: UTF8.self) == "dream-worker: protocolFailure\n")
    } else {
      #expect(diagnostic.isEmpty)
    }
  }
}

private func workerBytes(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(
    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
}

private func workerStart(
  _ fixture: TransactionFixture, resume: String = "inspectOrContinue", sessions: URL? = nil,
  snippets: URL? = nil, isStripping: Bool = true
) -> [String: Any] {
  [
    "version": 1, "type": "start", "invocationID": "synthetic-worker",
    "roots": [
      "state": fixture.state.path, "sessions": (sessions ?? fixture.sessions).path,
      "memory": fixture.memory.path,
      "snippets": isStripping ? (snippets ?? fixture.snippets).path as Any : NSNull(),
      "prompts": NSNull(), "globalAgents": NSNull(),
    ],
    "selection": [
      "provider": fixture.selection.provider, "modelID": fixture.selection.modelID,
      "thinkingLevel": fixture.selection.thinkingLevel,
    ], "resume": resume, "batchTextBytes": 262_144,
  ]
}

private func workerReply(_ request: [String: Any], text: String? = nil, category: String? = nil)
  -> [String: Any]
{
  var reply: [String: Any] = [
    "version": 1, "type": category == nil ? "modelResponse" : "modelFailure",
  ]
  for key in ["invocationID", "requestID", "runID", "inputHash", "contextHash", "requestHash"] {
    reply[key] = request[key]
  }
  if let category {
    reply["category"] = category
  } else {
    reply["text"] = text ?? "invalid decision"
  }
  return reply
}

private func workerDecision(_ request: [String: Any], isProposal: Bool = false) throws -> String {
  let messages = try #require(request["messages"] as? [[String: Any]])
  let text = try #require(messages.first?["text"] as? String)
  let context = try #require(
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  let primary = try #require(context["primaryEvidence"] as? [[String: Any]])
  let decisions = primary.map { entry -> [String: Any] in
    if isProposal {
      return [
        "kind": "add", "scope": ["kind": "global"], "text": "Use green buttons.",
        "sources": [entry["source"]!], "contradictions": [], "reason": "Retain the preference.",
      ]
    }
    return [
      "kind": "noChange", "sources": [entry["source"]!], "reasonCode": "notDurable",
      "explanation": "Synthetic Unicode café 🌱 note.",
    ]
  }
  let bytes = try JSONSerialization.data(
    withJSONObject: [
      "schemaVersion": 1, "contextHash": request["contextHash"]!,
      "decisions": decisions,
    ], options: [.sortedKeys, .withoutEscapingSlashes])
  return String(decoding: bytes, as: UTF8.self)
}

@Test(arguments: [false, true])
func dreamWorkerCompletesOneGenerationAndRepeatMakesNoRequest(isProposal: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Use green buttons, café 🌱, not blue."])
  let before = try fixture.protectedState()
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  try first.send(workerStart(fixture), isFragmented: true)
  let request = try first.frame()
  #expect(request["type"] as? String == "modelRequest")
  #expect(request["generation"] as? String == "0")
  #expect(
    request["requestID"] as? String == (request["runID"] as! String) + ":"
      + (request["requestHash"] as! String))
  try first.send(
    workerReply(request, text: workerDecision(request, isProposal: isProposal)), isFragmented: true)
  let final = try first.frame()
  #expect(final["status"] as? String == "completed")
  #expect(final["generation"] as? String == "1")
  #expect((final["proposals"] as? [[String: Any]])?.count == (isProposal ? 1 : 0))
  #expect((final["notes"] as? [[String: Any]])?.count == (isProposal ? 0 : 1))
  #expect(
    Set(final.keys) == [
      "version", "type", "invocationID", "status", "generation", "runID", "base", "proposals",
      "notes", "isBacklog", "isRecovered", "reason", "detail", "unfinishedTails",
    ])
  try first.finish()
  #expect(try fixture.protectedState() == before)
  let second = try DreamWorkerProcess()
  defer { second.clean() }
  try second.send(workerStart(fixture))
  let next = try second.frame()
  #expect(next["status"] as? String == "noNewRecords")
  #expect(next["generation"] as? String == "1")
  try second.finish()
  let recovery = try DreamWorkerProcess()
  defer { recovery.clean() }
  try recovery.send(workerStart(fixture, resume: "retryInterruptedCall"))
  let recovered = try recovery.frame()
  #expect(recovered["status"] as? String == "completed")
  #expect(recovered["generation"] as? String == "1")
  #expect(recovered["runID"] as? String == final["runID"] as? String)
  #expect(recovered["isRecovered"] as? Bool == true)
  let planned = try #require(first.progressFrames.first?["plannedBytes"] as? UInt64)
  #expect(planned > 0)
  #expect(first.progressFrames.first?["backlogBytes"] as? UInt64 == planned)
  #expect(first.progressFrames.first?["undreamtBytes"] as? UInt64 == planned)
  #expect(recovery.progressFrames.first?["backlogBytes"] is NSNull)
  #expect(recovery.progressFrames.first?["plannedBytes"] as? UInt64 == planned)
  #expect(recovery.progressFrames.last?["completedBytes"] as? UInt64 == planned)
  try recovery.finish()
}

@Test(arguments: [
  "wrongID", "wrongHash", "unknown", "duplicate", "oversize", "partial", "wrongOrder", "extra",
  "invalidUTF8", "modelFailure",
])
func dreamWorkerRejectsMalformedRepliesWithoutProgress(kind: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let before = try fixture.protectedState()
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(workerStart(fixture))
  let request = try worker.frame()
  var reply = workerReply(request, text: try workerDecision(request))
  switch kind {
  case "wrongID": reply["invocationID"] = "wrong"
  case "wrongHash": reply["requestHash"] = String(repeating: "0", count: 64)
  case "unknown": reply["unexpected"] = "private source body must not appear in diagnostics"
  case "oversize": reply["text"] = String(repeating: "a", count: 262_145)
  case "wrongOrder": reply = workerStart(fixture)
  case "modelFailure": reply = workerReply(request, category: "failed")
  default: break
  }
  if kind == "duplicate" {
    var bytes = try workerBytes(reply)
    bytes.removeLast(2)
    bytes.append(Data(",\"version\":1}\n".utf8))
    try worker.sendRaw(bytes)
  } else if kind == "partial" {
    let bytes = try workerBytes(reply)
    try worker.sendRaw(Data(bytes.dropLast(2)))
    try worker.closeInput()
  } else if kind == "invalidUTF8" {
    try worker.sendRaw(Data([123, 34, 255, 34, 58, 49, 125, 10]))
  } else if kind == "extra" {
    let bytes = try workerBytes(reply)
    try worker.sendRaw(bytes + bytes)
  } else {
    try worker.send(reply)
  }
  let final = try worker.frame()
  #expect(final["status"] as? String == (kind == "modelFailure" ? "pending" : "blocked"))
  #expect(final["generation"] as? String == "0")
  if kind == "modelFailure" { #expect(final["reason"] as? String == "callbackFailure") }
  try worker.finish()
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
  #expect(try fixture.protectedState() == before)
}

@Test(arguments: ["before", "inModel", "afterResponse", "eof", "modelCancelled", "incomplete"])
func dreamWorkerCancellationNeverAdvancesGeneration(phase: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  let cancel: [String: Any] = ["version": 1, "type": "cancel", "invocationID": "synthetic-worker"]
  if phase == "before" {
    try worker.sendRaw(workerBytes(workerStart(fixture)) + workerBytes(cancel))
  } else {
    try worker.send(workerStart(fixture))
    let request = try worker.frame()
    if phase == "afterResponse" {
      try worker.sendRaw(
        workerBytes(workerReply(request, text: workerDecision(request))) + workerBytes(cancel))
    } else if phase == "eof" {
      try worker.closeInput()
    } else if phase == "modelCancelled" || phase == "incomplete" {
      try worker.send(
        workerReply(request, category: phase == "modelCancelled" ? "cancelled" : "incomplete"))
    } else {
      try worker.send(cancel)
    }
  }
  let final = try worker.frame()
  #expect(final["status"] as? String != "completed")
  #expect(final["generation"] as? String == "0")
  if ["inModel", "modelCancelled", "eof"].contains(phase) {
    #expect(final["reason"] as? String == "cancelled")
  } else if phase == "incomplete" {
    #expect(final["reason"] as? String == "callbackFailure")
  }
  try worker.finish()
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}

@Test func dreamWorkerKilledCallRequiresExplicitExactRetryAndReleasesLock() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  try first.send(workerStart(fixture))
  let request = try first.frame()
  let busy = try DreamWorkerProcess()
  defer { busy.clean() }
  try busy.send(workerStart(fixture))
  #expect(try busy.frame()["status"] as? String == "busy")
  try busy.finish()
  first.clean()
  let pending = try DreamWorkerProcess()
  defer { pending.clean() }
  try pending.send(workerStart(fixture))
  let interrupted = try pending.frame()
  #expect(interrupted["status"] as? String == "pending")
  #expect(interrupted["reason"] as? String == "interruptedCall")
  try pending.finish()
  try FileManager.default.removeItem(at: fixture.sessions)
  try FileManager.default.removeItem(at: fixture.snippets)
  let retry = try DreamWorkerProcess()
  defer { retry.clean() }
  try retry.send(workerStart(fixture, resume: "retryInterruptedCall"))
  let replay = try retry.frame()
  #expect(NSDictionary(dictionary: replay).isEqual(to: request))
  try retry.send(workerReply(replay, text: workerDecision(replay)))
  #expect(try retry.frame()["status"] as? String == "completed")
  try retry.finish()
}

@Test func dreamWorkerSavedResponseReplaysWithoutModelUnderChangedSelection() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let core = try fixture.store()
  core.persistenceFault = {
    if $0 == .afterDirectorySync("response.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try core.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: transactionNotes)
  }
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  var changed = workerStart(fixture)
  changed["selection"] = ["provider": "other", "modelID": "other", "thinkingLevel": "high"]
  try worker.send(changed)
  #expect(try worker.frame()["status"] as? String == "completed")
  try worker.finish()
  try FileManager.default.removeItem(at: fixture.sessions)
  try FileManager.default.removeItem(at: fixture.snippets)
  let recovery = try DreamWorkerProcess()
  defer { recovery.clean() }
  try recovery.send(workerStart(fixture, resume: "retryInterruptedCall"))
  let final = try recovery.frame()
  #expect(final["status"] as? String == "completed")
  #expect(final["generation"] as? String == "1")
  try recovery.finish()
}

@Test(arguments: [false, true])
func dreamWorkerExactReplyByteLimitPreservesUnmodifiedText(isEscaped: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(workerStart(fixture))
  let request = try worker.frame()
  let text = String(repeating: isEscaped ? "\u{1}" : "a", count: 262_144)
  try worker.send(workerReply(request, text: text))
  let final = try worker.frame()
  #expect(final["status"] as? String == "pending")
  #expect(final["reason"] as? String == "invalidDecision")
  try worker.finish()
  let response =
    try JSONSerialization.jsonObject(
      with: Data(contentsOf: fixture.payload("response.json"))) as! [String: Any]
  #expect(response["text"] as? String == text)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}

@Test(arguments: ["snippets", "prompts"])
func dreamWorkerExplicitEmptyStrippingFolderIsBlocked(role: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let empty = fixture.root.appendingPathComponent("empty-stripping")
  try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
  var start = workerStart(fixture, isStripping: false)
  var roots = start["roots"] as! [String: Any]
  roots[role] = empty.path
  start["roots"] = roots
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(start)
  let final = try worker.frame()
  #expect(final["status"] as? String == "blocked")
  #expect(final["reason"] as? String == "workerFailure")
  #expect(
    final["detail"] as? String
      == (role == "snippets"
        ? "no snippet bodies in --snippets" : "no prompt templates in --prompts"))
  try worker.finish()
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}

@Test func dreamWorkerExclusionsOnlyCompletesWithoutModelRequest() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.write(
    dreamHeader("one", cwd: fixture.root.path, name: nil) + "\n", file: fixture.source)
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(workerStart(fixture))
  let final = try worker.frame()
  #expect(final["status"] as? String == "completed")
  #expect(final["generation"] as? String == "1")
  #expect((final["proposals"] as? [[String: Any]])?.isEmpty == true)
  try worker.finish()
}

@Test func dreamWorkerAliasesReopenAndOptionalStrippingIsSupported() throws {
  for isStripping in [false, true] {
    let fixture = try TransactionFixture()
    defer { fixture.clean() }
    try fixture.populate()
    let alias = fixture.root.appendingPathComponent("source-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.sessions)
    for index in 0..<2 {
      let worker = try DreamWorkerProcess()
      defer { worker.clean() }
      try worker.send(workerStart(fixture, sessions: alias, isStripping: isStripping))
      if index == 0 {
        let request = try worker.frame()
        try worker.send(workerReply(request, text: workerDecision(request)))
        #expect(try worker.frame()["status"] as? String == "completed")
      } else {
        #expect(try worker.frame()["status"] as? String == "noNewRecords")
      }
      try worker.finish()
    }
  }
}

@Test(arguments: [
  "duplicate", "unknown", "versionBool", "versionFraction", "unsafeID", "wrongType", "partial",
  "oversize", "budgetMissing", "budgetLow", "budgetHigh", "budgetBool", "budgetFraction",
])
func dreamWorkerRejectsMalformedStartBeforeCreatingState(kind: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  var start = workerStart(fixture)
  switch kind {
  case "unknown": start["unknown"] = "private"
  case "versionBool": start["version"] = true
  case "versionFraction": start["version"] = 1.5
  case "unsafeID": start["invocationID"] = "unsafe\nidentifier"
  case "wrongType": start["type"] = "modelResponse"
  case "oversize": start["invocationID"] = String(repeating: "a", count: 65_537)
  case "budgetMissing": start["batchTextBytes"] = nil
  case "budgetLow": start["batchTextBytes"] = 65_535
  case "budgetHigh": start["batchTextBytes"] = 1_048_577
  case "budgetBool": start["batchTextBytes"] = true
  case "budgetFraction": start["batchTextBytes"] = 65_536.5
  default: break
  }
  if kind == "duplicate" {
    var bytes = try workerBytes(start)
    bytes.removeLast(2)
    bytes.append(Data(",\"roots\":{}}\n".utf8))
    try worker.sendRaw(bytes)
  } else if kind == "partial" {
    try worker.sendRaw(Data(try workerBytes(start).dropLast(2)))
    try worker.closeInput()
  } else {
    try worker.send(start)
  }
  try worker.finish(status: 1, isErrorExpected: true)
  #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
}
