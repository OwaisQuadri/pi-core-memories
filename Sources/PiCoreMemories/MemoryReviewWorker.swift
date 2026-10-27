import CoreMemories
import Darwin
import Foundation

private enum ReviewControlFailure: Error {
  case owner, fifoLinks, kind, listening, socketName
}

func reviewControlDescriptor() throws -> Int32 {
  let descriptor: Int32 = 3
  var status = stat()
  guard fstat(descriptor, &status) == 0, status.st_uid == geteuid() else {
    throw ReviewControlFailure.owner
  }
  if status.st_mode & S_IFMT == S_IFIFO {
    guard status.st_nlink == 0 else { throw ReviewControlFailure.fifoLinks }
  } else {
    guard status.st_mode & S_IFMT == S_IFSOCK else { throw ReviewControlFailure.kind }
    var listening: Int32 = 1
    var size = socklen_t(MemoryLayout<Int32>.size)
    let option = getsockopt(descriptor, SOL_SOCKET, SO_ACCEPTCONN, &listening, &size)
    guard (option == 0 && listening == 0) || (option == -1 && errno == ENOPROTOOPT)
    else { throw ReviewControlFailure.listening }
    for isPeer in [false, true] {
      var address = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          isPeer ? getpeername(descriptor, $0, &length) : getsockname(descriptor, $0, &length)
        }
      }
      guard result == 0, Int32(address.ss_family) == AF_UNIX,
        length >= 2, length <= MemoryLayout<sockaddr_un>.size,
        withUnsafeBytes(of: address, { bytes in bytes[2..<Int(length)].allSatisfy { $0 == 0 } })
      else { throw ReviewControlFailure.socketName }
    }
  }
  return descriptor
}

private final class ReviewInput: @unchecked Sendable {
  private let condition = NSCondition()
  private var events: [(Bool, [String: Any])] = []
  private var isStopped = false
  private var expected: (String, String, String)?
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

  func expect(sequence: String, candidate: String, digest: String) {
    condition.lock()
    expected = (sequence, candidate, digest)
    condition.unlock()
  }

  func clear() {
    condition.lock()
    expected = nil
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
        if !isControl && type == "cancel" {
          try WorkerJSON.fields(object, ["version", "type", "invocationID"])
          stop()
          return
        }
        condition.lock()
        do {
          if isControl {
            try WorkerJSON.fields(
              object,
              ["version", "type", "invocationID", "sequence", "candidateID", "digest", "action"])
            guard type == "choice", let expected,
              try WorkerJSON.text(object, "sequence") == expected.0,
              try WorkerJSON.text(object, "candidateID") == expected.1,
              try WorkerJSON.text(object, "digest") == expected.2,
              ["approve", "detach", "reject", "defer"].contains(
                try WorkerJSON.text(object, "action"))
            else { throw WorkerError.protocolFailure }
            self.expected = nil
          } else {
            guard ["list", "preview", "finish"].contains(type) else {
              throw WorkerError.protocolFailure
            }
            try WorkerJSON.fields(
              object,
              type == "preview"
                ? ["version", "type", "invocationID", "candidateID"]
                : ["version", "type", "invocationID"])
          }
          guard events.count < 2, !isStopped else { throw WorkerError.protocolFailure }
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

private func reviewQuote(_ source: PrimaryTextEvidence) -> String {
  let day = String(source.timestamp.ISO8601Format().prefix(10))
  return "  “\(source.exactText)”\n  — you \(source.kind.rawValue), \(day)"
}

private func reviewSource(_ source: PrimaryTextEvidence) -> String {
  "Reference: \(source.id.citation.session):\(source.id.citation.entry):\(source.id.part)\nKind: \(source.kind.rawValue)\nRecord: \(source.witness.relativePath.rawValue) [\(source.witness.byteRange.lowerBound), \(source.witness.byteRange.upperBound))\nRecord hash: \(source.witness.rawRecordHash.rawValue)"
}

private func reviewText(_ bytes: Data) -> String {
  var text = String(decoding: bytes, as: UTF8.self)
  for pattern in [
    #"\[source: [^\[\];\r\n]+; added: [0-9]{4}-[0-9]{2}-[0-9]{2}\]"#,
    #"\[memory-id: [0-9a-f-]+(?:; (?:reviewed|revised): [^\[\];\r\n]+)*\]"#,
  ] {
    let annotation = try! NSRegularExpression(pattern: pattern)
    text = annotation.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
  }
  return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func reviewDetails(_ change: AtomicMemoryChange, before: Data, after: Data) -> String {
  var lines = [
    "\(change.operation == .add ? "Add to" : "Update in") \(change.path):", "",
    reviewText(after), "",
  ]
  if change.operation != .add {
    lines += [
      "Replaces:", "", reviewText(before),
      "",
    ]
  }
  lines += ["Why: \(change.reason)", "", "Evidence (\(change.sources.count)):"]
  lines += change.sources.map(reviewQuote)
  lines += ["", "Known conflicts: \(change.contradictions.isEmpty ? "none supplied" : "")"]
  for conflict in change.contradictions {
    switch conflict {
    case .primary(let source, let explanation): lines += [reviewQuote(source), explanation]
    case .memory(let anchor, let explanation):
      lines += [
        "Memory anchor: \(anchor.scope) \(anchor.documentHash.rawValue) [\(anchor.start), \(anchor.end))",
        anchor.before, explanation,
      ]
    case .owner(let anchor, let reference, let scope, let explanation):
      lines += [
        "Owner: \(reference) \(scope) \(anchor.key) \(anchor.ownerHash.rawValue) [\(anchor.start), \(anchor.end))",
        anchor.before, explanation,
      ]
    }
  }
  return lines.joined(separator: "\n")
}

func executeMemoryReviewWorker(
  arguments: [String], configureController: (MemoryReviewController) -> Void = { _ in }
) -> Int32 {
  var invocation = ""
  var phase = "control"
  func emit(_ type: String, _ fields: [String: Any] = [:]) throws {
    var object = fields
    object["version"] = 1
    object["type"] = type
    object["invocationID"] = invocation
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    guard data.count <= 8 * 1_048_576 else { throw WorkerError.protocolFailure }
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
  }
  do {
    guard arguments == ["memory-review-worker"] else { throw WorkerError.protocolFailure }
    let control = try reviewControlDescriptor()
    phase = "start"
    let start = try WorkerJSON.object(ReviewInput.line(STDIN_FILENO))
    try WorkerJSON.fields(start, ["version", "type", "invocationID", "roots", "reviewState"])
    guard try WorkerJSON.header(start) == "start", let roots = start["roots"] as? [String: Any]
    else {
      throw WorkerError.protocolFailure
    }
    try WorkerJSON.fields(
      roots, ["state", "sessions", "memory", "snippets", "prompts", "globalAgents"])
    invocation = try WorkerJSON.identifier(start, "invocationID")
    func url(_ object: [String: Any], _ key: String) throws -> URL {
      let path = try WorkerJSON.text(object, key)
      guard path.hasPrefix("/") else { throw WorkerError.protocolFailure }
      return URL(fileURLWithPath: path)
    }
    let state = try url(roots, "state")
    guard FileManager.default.fileExists(atPath: state.appendingPathComponent("root.json").path)
    else {
      try emit(
        "final",
        [
          "status": "blocked",
          "reason":
            "No saved dream run is available. Pending work stays queued for background dreaming.",
        ])
      return 0
    }
    let input = ReviewInput(invocation: invocation)
    Thread.detachNewThread { input.read(descriptor: STDIN_FILENO, isControl: false) }
    Thread.detachNewThread { input.read(descriptor: control, isControl: true) }
    defer { input.stop() }
    phase = "sources"
    let sources = try DreamRunStore(
      stateRoot: state, sessionsRoot: url(roots, "sessions"),
      memoryRepository: url(roots, "memory"),
      strippingRoots: ["snippets", "prompts"].compactMap { key in
        roots[key] is NSNull ? nil : try url(roots, key)
      }, globalAgents: roots["globalAgents"] is NSNull ? nil : url(roots, "globalAgents"),
      isCancelled: { input.isCancelled })
    phase = "controller"
    let controller = try MemoryReviewController(
      repository: sources.acceptedSources.memory,
      stateRoot: url(start, "reviewState"), sources: sources,
      environment: ProcessInfo.processInfo.environment)
    controller.isCancelled = { input.isCancelled }
    configureController(controller)
    var sequence: UInt64 = 0
    var preview: MemoryReviewPreview?
    var checkout: MemoryReviewCheckoutPreview?
    func queue() throws {
      input.clear()
      preview = nil
      checkout = nil
      let rows = try controller.list().map { item -> [String: Any] in
        [
          "candidateID": item.change.id.rawValue, "path": item.change.path,
          "operation": item.change.operation.rawValue, "disposition": item.disposition.rawValue,
          "limitation": item.limitation as Any? ?? NSNull(),
          "frozenLimitations": item.frozenLimitations,
        ]
      }
      try emit("queue", ["candidates": rows])
    }
    phase = "queue"
    try queue()
    phase = "interaction"
    while true {
      let (isControl, object) = try input.next()
      let type = try WorkerJSON.header(object)
      if !isControl {
        switch type {
        case "finish":
          try emit("final", ["status": "completed", "reason": NSNull()])
          return 0
        case "list": try queue()
        case "preview":
          input.clear()
          preview = nil
          checkout = nil
          let id = try WorkerJSON.text(object, "candidateID", maximum: 64)
          guard let candidate = try controller.list().first(where: { $0.change.id.rawValue == id })
          else {
            throw WorkerError.protocolFailure
          }
          do {
            let current = try controller.preview(
              candidateID: candidate.change.id, clockDate: Date())
            let currentCheckout = try controller.checkoutPreview()
            sequence += 1
            preview = current
            checkout = currentCheckout
            let digest =
              currentCheckout.isDetachRequired
              ? currentCheckout.digest.rawValue : current.digest.rawValue
            input.expect(sequence: String(sequence), candidate: id, digest: digest)
            let change = current.change
            let audit = [
              "", "Audit", "Candidate: \(change.id.rawValue)", "Frozen base: \(change.base)",
              "Current base: \(current.currentBase)", "Input: \(change.inputHash.rawValue)",
              "Context: \(change.contextHash.rawValue)",
              "Response: \(change.responseHash.rawValue)",
              "Identity: \(current.identity.uuidString)",
              "Review instant: \(current.instant.rawValue)",
              "Frozen limitations: \(candidate.frozenLimitations.isEmpty ? "none supplied" : candidate.frozenLimitations.joined(separator: "\n"))",
              "Sources:",
            ]
            let details =
              reviewDetails(change, before: current.before, after: current.after)
              + (audit + change.sources.map(reviewSource)).joined(separator: "\n")
              + "\nExact old bytes:\n\(String(decoding: current.before, as: UTF8.self))\nExact final new bytes:\n\(String(decoding: current.after, as: UTF8.self))"
            try emit(
              "preview",
              [
                "candidateID": id, "sequence": String(sequence), "digest": digest,
                "isDetachRequired": currentCheckout.isDetachRequired,
                "checkoutCommit": currentCheckout.commit,
                "details": details,
              ])
          } catch {
            try emit(
              "operation",
              [
                "status": "blocked", "candidateID": id, "commit": NSNull(), "auditRef": NSNull(),
                "reason": "\(error)",
              ])
            try queue()
          }
        default: throw WorkerError.protocolFailure
        }
      } else {
        guard let current = preview, let currentCheckout = checkout else {
          throw WorkerError.protocolFailure
        }
        preview = nil
        checkout = nil
        let action = try WorkerJSON.text(object, "action")
        do {
          if action == "detach" {
            guard currentCheckout.isDetachRequired else { throw WorkerError.protocolFailure }
            try controller.confirmDetach(currentCheckout)
            try emit(
              "operation",
              [
                "status": "detached", "candidateID": current.change.id.rawValue,
                "commit": currentCheckout.commit, "auditRef": NSNull(), "reason": NSNull(),
              ])
          } else if action == "approve" {
            guard !currentCheckout.isDetachRequired else { throw WorkerError.protocolFailure }
            let approval = try controller.apply(current)
            try emit(
              "operation",
              [
                "status": "approved", "candidateID": approval.candidateID.rawValue,
                "commit": approval.commit, "auditRef": approval.auditRef, "reason": NSNull(),
              ])
          } else {
            if action == "reject" {
              try controller.reject(candidateID: current.change.id)
            } else {
              try controller.deferCandidate(candidateID: current.change.id)
            }
            try emit(
              "operation",
              [
                "status": action == "reject" ? "rejected" : "deferred",
                "candidateID": current.change.id.rawValue, "commit": NSNull(), "auditRef": NSNull(),
                "reason": NSNull(),
              ])
          }
        } catch {
          let mutation = error as? MemoryReviewMutationFailure
          try emit(
            "operation",
            [
              "status": mutation?.mutation.rawValue ?? "blocked",
              "candidateID": current.change.id.rawValue,
              "commit": mutation?.commit as Any? ?? NSNull(),
              "auditRef": mutation?.auditRef as Any? ?? NSNull(), "reason": "\(error)",
            ])
        }
        try queue()
      }
    }
  } catch {
    let category = (error as? ReviewControlFailure).map { ": \($0)" } ?? ""
    try? emit(
      "final",
      [
        "status": "failed",
        "reason": "Private memory review stopped at \(phase)\(category); request a fresh preview.",
      ])
    return 1
  }
}
