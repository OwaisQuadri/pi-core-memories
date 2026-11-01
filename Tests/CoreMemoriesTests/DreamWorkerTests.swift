import Darwin
import Foundation
import Testing

@testable import CoreMemories
@testable import PiCoreMemories

final class DreamWorkerProcess {
  let process = Process()
  let input = Pipe()
  let output = Pipe()
  let error = Pipe()
  private var buffered = Data()
  private let deadline = Date().addingTimeInterval(20)

  init(arguments: [String] = ["dream-worker"]) throws {
    let binary = try #require(
      ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_BIN"]
        ?? ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_EXECUTABLE"])
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

  var progressFrames: [[String: Any]] = []
  var protectionCount = 0
  var isProtectingAutomatically = true
  var protectionTransform: ([String]) -> [String] = { $0 }

  func frame() throws -> [String: Any] {
    while true {
      if let newline = buffered.firstIndex(of: 10) {
        let bytes = buffered[..<newline]
        buffered.removeSubrange(...newline)
        let frame = try #require(
          try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        if frame["type"] as? String == "sourceProtectionRequest", isProtectingAutomatically {
          protectionCount += 1
          try send(
            workerProtectionReply(frame, pieces: protectionTransform(frame["pieces"] as! [String])))
          continue
        }
        if frame["type"] as? String == "progress" {
          progressFrames.append(frame)
          #expect(
            Set(frame.keys) == [
              "version", "type", "invocationID", "backlogBytes", "backlogLimitBytes",
              "plannedBytes", "completedBytes", "undreamtBytes", "nextBytes", "repeatedRecords",
              "estimateSeconds",
            ])
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

func workerStart(
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

func workerProtectionReply(_ request: [String: Any], pieces: [String]? = nil) -> [String: Any] {
  let checked = pieces ?? (request["pieces"] as! [String])
  return [
    "version": 1, "type": "sourceProtectionResult", "invocationID": request["invocationID"]!,
    "requestID": request["requestID"]!, "inputDigest": request["inputDigest"]!,
    "status": "checked", "policy": "pi-credentials/redact-v1", "pieces": checked,
    "outputDigest": DreamSourceProtection.digest(checked).rawValue,
  ]
}

func workerReply(_ request: [String: Any], text: String? = nil, category: String? = nil)
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

func workerDecision(_ request: [String: Any], isProposal: Bool = false) throws -> String {
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
  let callSelection = try #require(interrupted["callSelection"] as? [String: Any])
  #expect(NSDictionary(dictionary: callSelection).isEqual(to: request["selection"] as? [String: Any] ?? [:]))
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

private enum PrivateMirrorError: Error, CustomReflectable {
  case failure(String)

  var customMirror: Mirror {
    Mirror(self, children: ["private-folder-name": "private-folder-name"], displayStyle: .enum)
  }
}

@Test func dreamWorkerFailureDetailNamesErrorWithoutAssociatedValues() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let privateName = "private-folder-name"
  try FileManager.default.createSymbolicLink(
    at: fixture.sessions.appendingPathComponent(privateName), withDestinationURL: fixture.root)
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(workerStart(fixture))
  let final = try worker.frame()
  #expect(final["status"] as? String == "blocked")
  #expect(final["reason"] as? String == "workerFailure")
  #expect(final["detail"] as? String == "MemoryError")
  try worker.finish()
  #expect(dreamWorkerFailureName(DreamRunError.corruption) == "DreamRunError.corruption")
  #expect(
    dreamWorkerFailureName(DreamRunError.nativeReviewLimitation(privateName))
      == "DreamRunError.nativeReviewLimitation")
  #expect(
    dreamWorkerFailureName(DreamDecisionError.context(fixture.root.path))
      == "DreamDecisionError.context")
  #expect(dreamWorkerFailureName(DreamDecisionError.schema) == "DreamDecisionError.schema")
  #expect(dreamWorkerFailureName(PrivateMirrorError.failure(privateName)) == "PrivateMirrorError")
}
