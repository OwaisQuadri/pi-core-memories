import CoreMemories
import Darwin
import Foundation

private final class QueueInput: @unchecked Sendable {
  private let condition = NSCondition()
  private var events: [(Bool, [String: Any])] = []
  private var expected: ([String: String], String)?
  private var isStopped = false
  let invocation: String

  init(invocation: String) { self.invocation = invocation }

  var isCancelled: Bool {
    condition.lock()
    defer { condition.unlock() }
    return isStopped
  }

  func stop() {
    condition.lock()
    isStopped = true
    condition.broadcast()
    condition.unlock()
  }

  func expect(_ display: MemoryQueueDisplay?, type: String = "presented") {
    condition.lock()
    expected = display.map { (queueTuple($0), type) }
    condition.unlock()
  }

  func expectManagement(_ display: MemoryManagementDisplay, type: String = "manage-presented") {
    condition.lock()
    expected = (managementTuple(display), type)
    condition.unlock()
  }

  func read(descriptor: Int32, isControl: Bool) {
    do {
      while !isCancelled {
        let object = try WorkerJSON.object(Self.line(descriptor))
        let type = try WorkerJSON.header(object)
        guard try WorkerJSON.identifier(object, "invocationID") == invocation else {
          throw WorkerError.protocolFailure
        }
        condition.lock()
        do {
          if isControl {
            guard let (display, requiredType) = expected, type == requiredType else {
              throw WorkerError.protocolFailure
            }
            try matchTuple(object, tuple: display)
            expected = nil
          } else {
            guard
              [
                "list", "claim", "release", "recover", "inventory", "finish", "cancel",
                "approved-list", "approved-get", "manage-preview", "manage-recover",
              ].contains(
                type)
            else { throw WorkerError.protocolFailure }
          }
          guard events.count < 4, !isStopped else { throw WorkerError.protocolFailure }
          if type == "cancel" { isStopped = true }
          events.append((isControl, object))
          condition.signal()
          condition.unlock()
        } catch {
          condition.unlock()
          throw error
        }
      }
    } catch { stop() }
  }

  func next() throws -> (Bool, [String: Any]) {
    condition.lock()
    defer { condition.unlock() }
    while events.isEmpty && !isStopped { condition.wait() }
    guard !isStopped else { throw WorkerError.cancelled }
    return events.removeFirst()
  }

  static func line(_ descriptor: Int32) throws -> Data {
    var bytes = Data()
    var byte: UInt8 = 0
    while bytes.count < 65_536 {
      let count = Darwin.read(descriptor, &byte, 1)
      if count < 0 && errno == EINTR { continue }
      guard count == 1 else { throw WorkerError.protocolFailure }
      if byte == 10 { return bytes }
      bytes.append(byte)
    }
    throw WorkerError.protocolFailure
  }
}

private func queueTuple(_ display: MemoryQueueDisplay) -> [String: String] {
  let presentation = display.presentation
  return [
    "claimID": presentation.claimID, "sequence": presentation.sequence,
    "revision": presentation.finding.revision, "previewDigest": presentation.previewDigest,
    "displayDigest": display.displayDigest, "sessionID": presentation.request.sessionID,
    "requestID": presentation.request.requestID,
  ]
}

private func managementTuple(_ display: MemoryManagementDisplay) -> [String: String] {
  [
    "claimID": display.claimID, "sequence": display.sequence, "revision": display.currentBase,
    "previewDigest": display.previewDigest,
    "displayDigest": display.displayDigest, "sessionID": display.request.sessionID,
    "requestID": display.request.requestID,
  ]
}

private func matchTuple(_ object: [String: Any], tuple: [String: String]) throws {
  for (key, value) in tuple {
    guard try WorkerJSON.text(object, key) == value else { throw WorkerError.protocolFailure }
  }
}

private func queueMatch(_ object: [String: Any], display: MemoryQueueDisplay) throws {
  try matchTuple(object, tuple: queueTuple(display))
}

func executeMemoryQueueWorker(arguments: [String]) -> Int32 {
  var invocation = ""
  func emit(_ type: String, _ fields: [String: Any] = [:]) throws {
    var object = fields
    object["version"] = 1
    object["type"] = type
    object["invocationID"] = invocation
    let bytes = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    guard bytes.count <= 8 * 1_048_576 else { throw WorkerError.protocolFailure }
    try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
  }
  func encoded(_ value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }
  do {
    guard arguments == ["memory-queue-worker"] else { throw WorkerError.protocolFailure }
    let control = try reviewControlDescriptor()
    guard fcntl(control, F_SETFD, FD_CLOEXEC) == 0 else { throw WorkerError.protocolFailure }
    let start = try WorkerJSON.object(QueueInput.line(STDIN_FILENO))
    try WorkerJSON.fields(start, ["version", "type", "invocationID", "config"])
    guard try WorkerJSON.header(start) == "start" else { throw WorkerError.protocolFailure }
    invocation = try WorkerJSON.identifier(start, "invocationID")
    let configURL: URL
    if start["config"] is NSNull {
      configURL = MemoryConfiguration.defaultURL
    } else {
      let path = try WorkerJSON.text(start, "config")
      guard path.hasPrefix("/") else { throw WorkerError.protocolFailure }
      configURL = URL(fileURLWithPath: path)
    }
    let configuration = try MemoryConfiguration.load(from: configURL)
    let sources = try? configuration.reviewSources()
    let queue = try sources.map { sources in
      try MemoryQueue(
        sources: sources, reviewState: URL(fileURLWithPath: configuration.reviewState),
        journal: URL(fileURLWithPath: configuration.journal),
        environment: ProcessInfo.processInfo.environment)
    }
    let management = queue.map {
      MemoryQueueManagement(queue: $0, configurationURL: configURL, configuration: configuration)
    }
    var managementDisplay: MemoryManagementDisplay?
    let input = QueueInput(invocation: invocation)
    queue?.isCancelled = { input.isCancelled }
    Thread.detachNewThread { input.read(descriptor: STDIN_FILENO, isControl: false) }
    Thread.detachNewThread { input.read(descriptor: control, isControl: true) }
    defer {
      input.stop()
      management?.release()
      queue?.release()
    }
    let tuple: Set<String> = [
      "version", "type", "invocationID", "claimID", "sequence", "revision",
      "previewDigest", "displayDigest", "sessionID", "requestID",
    ]
    let header: Set<String> = ["version", "type", "invocationID"]
    var display: MemoryQueueDisplay?
    try emit(
      "ready",
      [
        "policyVersion": 1, "ownership": "whole-store", "successors": "source-bound-v1",
        "isReviewAvailable": queue != nil,
        "reason": queue == nil
          ? "verified dream sources unavailable; inventory only" as Any : NSNull(),
      ])
    while true {
      let (isControl, object) = try input.next()
      let type = try WorkerJSON.header(object)
      do {
        if !isControl, ["approved-list", "approved-get"].contains(type) {
          try WorkerJSON.fields(
            object, type == "approved-list" ? header : header.union(["request"]))
          let request =
            type == "approved-list"
            ? MemoryManagementRequest(operation: .list)
            : try MemoryManagementRequest.decode(
              JSONSerialization.data(withJSONObject: object["request"] as Any))
          guard [.list, .get].contains(request.operation) else { throw WorkerError.protocolFailure }
          try emit(
            "approved",
            [
              "result": encoded(
                MemoryManagement(repository: configuration.memoryURL).execute(request))
            ])
          continue
        }
        guard let queue else {
          guard !isControl, ["inventory", "finish"].contains(type) else {
            throw WorkerError.protocolFailure
          }
          try WorkerJSON.fields(object, header)
          if type == "finish" {
            try emit("final", ["status": "completed"])
            return 0
          }
          try emit(
            "inventory",
            ["inventory": encoded(MemoryQueueInventory.readOnly(configuration: configuration))])
          continue
        }
        if isControl, let current = managementDisplay, let management {
          try matchTuple(object, tuple: managementTuple(current))
          let managementFields = header.union(managementTuple(current).keys)
          if type == "manage-presented" {
            try WorkerJSON.fields(object, managementFields.union(["messageReference"]))
            try management.presented(
              current, messageReference: WorkerJSON.identifier(object, "messageReference"))
            input.expectManagement(current, type: "manage-choice")
            try emit("manage-presented", ["displayDigest": current.displayDigest])
          } else {
            try WorkerJSON.fields(
              object,
              managementFields.union(["action", "decisionID", "responseReference", "isInteractive"])
            )
            guard let isInteractive = object["isInteractive"] as? NSNumber,
              CFGetTypeID(isInteractive) == CFBooleanGetTypeID(), isInteractive.boolValue
            else { throw WorkerError.protocolFailure }
            let decisionID = try WorkerJSON.identifier(object, "decisionID")
            defer {
              management.release()
              managementDisplay = nil
              input.expect(nil)
            }
            do {
              let receipt = try management.decide(
                current, action: WorkerJSON.text(object, "action"), decisionID: decisionID,
                responseReference: WorkerJSON.identifier(object, "responseReference"))
              try emit("manage-decision", ["receipt": encoded(receipt)])
            } catch {
              if let receipt = try? management.recover(decisionID: decisionID) {
                try emit("manage-decision", ["receipt": encoded(receipt)])
              } else {
                try emit("blocked", ["code": "outcome-unresolved", "decisionID": decisionID])
              }
            }
          }
        } else if isControl {
          guard let current = display else { throw WorkerError.protocolFailure }
          try queueMatch(object, display: current)
          if type == "presented" {
            try WorkerJSON.fields(object, tuple.union(["messageReference"]))
            try queue.presented(
              current, messageReference: WorkerJSON.identifier(object, "messageReference"))
            input.expect(current, type: "choice")
            try emit("presented", ["displayDigest": current.displayDigest])
          } else {
            try WorkerJSON.fields(
              object, tuple.union(["action", "decisionID", "responseReference", "isInteractive"]))
            guard let isInteractive = object["isInteractive"] as? NSNumber,
              CFGetTypeID(isInteractive) == CFBooleanGetTypeID(), isInteractive.boolValue
            else { throw WorkerError.protocolFailure }
            let decisionID = try WorkerJSON.identifier(object, "decisionID")
            let action = try WorkerJSON.text(object, "action")
            let response = try WorkerJSON.identifier(object, "responseReference")
            defer {
              display = nil
              input.expect(nil)
              queue.release()
            }
            do {
              let receipt = try queue.decide(
                current, action: action, decisionID: decisionID, responseReference: response)
              try emit("decision", ["receipt": encoded(receipt)])
            } catch {
              if let receipt = try? queue.recover(decisionID: decisionID) {
                try emit("decision", ["receipt": encoded(receipt)])
              } else {
                try emit("blocked", ["code": "outcome-unresolved", "decisionID": decisionID])
              }
            }
          }
        } else {
          switch type {
          case "finish":
            try WorkerJSON.fields(object, header)
            try emit("final", ["status": "completed"])
            return 0
          case "release":
            try WorkerJSON.fields(object, header)
            input.expect(nil)
            display = nil
            managementDisplay = nil
            management?.release()
            queue.release()
            try emit("released")
          case "recover":
            try WorkerJSON.fields(object, header.union(["decisionID"]))
            let receipt = try queue.recover(decisionID: WorkerJSON.identifier(object, "decisionID"))
            try emit("decision", ["receipt": encoded(receipt)])
          case "inventory":
            try WorkerJSON.fields(object, header)
            let inventory = try queue.inventory(configuration: configuration)
            try emit("inventory", ["inventory": encoded(inventory)])
          case "manage-recover":
            guard let management else { throw WorkerError.protocolFailure }
            try WorkerJSON.fields(object, header.union(["decisionID"]))
            try emit(
              "manage-decision",
              [
                "receipt": encoded(
                  management.recover(decisionID: WorkerJSON.identifier(object, "decisionID")))
              ])
          case "manage-preview":
            guard display == nil, managementDisplay == nil, let management else {
              throw WorkerError.protocolFailure
            }
            try WorkerJSON.fields(
              object, header.union(["sessionID", "requestID", "request", "mode"]))
            let mode = try WorkerJSON.text(object, "mode")
            guard ["crud", "confirm-reviewed"].contains(mode) else {
              throw WorkerError.protocolFailure
            }
            let request = try MemoryManagementRequest.decode(
              JSONSerialization.data(withJSONObject: object["request"] as Any))
            let identity = try MemoryQueueRequest(
              sessionID: WorkerJSON.identifier(object, "sessionID"),
              requestID: WorkerJSON.identifier(object, "requestID"))
            let current = try management.preview(
              request, identity: identity, isConfirmReviewed: mode == "confirm-reviewed")
            managementDisplay = current
            input.expectManagement(current)
            try emit(
              "manage-presentation",
              [
                "display": encoded(current),
                "displayBytes": current.publicationBytes().base64EncodedString(),
              ])
          case "list", "claim":
            guard managementDisplay == nil else { throw WorkerError.protocolFailure }
            let fields =
              type == "list"
              ? ["sessionID", "requestID", "offset"] : ["sessionID", "requestID", "revision"]
            try WorkerJSON.fields(object, header.union(fields))
            let request = try MemoryQueueRequest(
              sessionID: WorkerJSON.identifier(object, "sessionID"),
              requestID: WorkerJSON.identifier(object, "requestID"))
            if type == "list" {
              let offsetText = try WorkerJSON.text(object, "offset", maximum: 10)
              guard let offset = Int(offsetText), offset >= 0, String(offset) == offsetText else {
                throw WorkerError.protocolFailure
              }
              let rows = try queue.list(request: request)
              guard offset <= rows.count else { throw WorkerError.protocolFailure }
              let end = min(rows.count, offset + 64)
              try emit(
                "queue",
                [
                  "rows": encoded(Array(rows[offset..<end])),
                  "nextOffset": end < rows.count ? String(end) as Any : NSNull(),
                ])
            } else {
              let current = try queue.claim(
                revision: WorkerJSON.text(object, "revision", maximum: 64), request: request)
              display = current
              input.expect(current)
              let encoder = JSONEncoder()
              encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
              try emit(
                "presentation",
                [
                  "display": encoded(current),
                  "displayBytes": encoder.encode(current.presentation).base64EncodedString(),
                ])
            }
          default: throw WorkerError.protocolFailure
          }
        }
      } catch is WorkerError {
        throw WorkerError.protocolFailure
      } catch {
        let code = (error as? DreamRunError) == .busy ? "busy" : "blocked"
        try emit("blocked", ["code": code])
      }
    }
  } catch {
    try? emit("final", ["status": "failed", "code": "protocol-or-binding-failure"])
    return 1
  }
}
