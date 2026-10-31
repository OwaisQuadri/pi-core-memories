import CoreMemories
import Darwin
import Foundation

enum WorkerError: Error, Equatable {
  case protocolFailure, cancelled, modelFailure
}

enum WorkerJSON {
  static func object(_ data: Data) throws -> [String: Any] {
    guard String(data: data, encoding: .utf8) != nil else { throw WorkerError.protocolFailure }
    var scanner = Scanner(bytes: Array(data))
    try scanner.value(depth: 0)
    scanner.space()
    guard scanner.index == scanner.bytes.count,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw WorkerError.protocolFailure }
    return object
  }

  private struct Scanner {
    let bytes: [UInt8]
    var index = 0

    mutating func space() {
      while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func take(_ byte: UInt8) throws {
      space()
      guard index < bytes.count, bytes[index] == byte else { throw WorkerError.protocolFailure }
      index += 1
    }

    mutating func string() throws -> String {
      space()
      let start = index
      try take(34)
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 92 {
          guard index < bytes.count else { throw WorkerError.protocolFailure }
          index += 1
        } else if byte == 34 {
          guard
            let text = try JSONSerialization.jsonObject(
              with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String
          else { throw WorkerError.protocolFailure }
          return text
        }
      }
      throw WorkerError.protocolFailure
    }

    mutating func value(depth: Int) throws {
      space()
      guard depth < 32, index < bytes.count else { throw WorkerError.protocolFailure }
      switch bytes[index] {
      case 123:
        index += 1
        space()
        if index < bytes.count, bytes[index] == 125 {
          index += 1
          return
        }
        var keys: Set<String> = []
        while true {
          let key = try string()
          guard keys.insert(key).inserted else { throw WorkerError.protocolFailure }
          try take(58)
          try value(depth: depth + 1)
          space()
          guard index < bytes.count else { throw WorkerError.protocolFailure }
          if bytes[index] == 125 {
            index += 1
            return
          }
          try take(44)
        }
      case 91:
        index += 1
        space()
        if index < bytes.count, bytes[index] == 93 {
          index += 1
          return
        }
        while true {
          try value(depth: depth + 1)
          space()
          guard index < bytes.count else { throw WorkerError.protocolFailure }
          if bytes[index] == 93 {
            index += 1
            return
          }
          try take(44)
        }
      case 34:
        _ = try string()
      default:
        let start = index
        while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
          index += 1
        }
        guard index > start else { throw WorkerError.protocolFailure }
        _ = try JSONSerialization.jsonObject(
          with: Data(bytes[start..<index]), options: [.fragmentsAllowed])
      }
    }
  }

  static func fields(_ object: [String: Any], _ keys: Set<String>) throws {
    guard Set(object.keys) == keys else { throw WorkerError.protocolFailure }
  }

  static func text(_ object: [String: Any], _ key: String, maximum: Int = 4096) throws -> String {
    guard let text = object[key] as? String, text.utf8.count <= maximum,
      !text.contains("\0")
    else { throw WorkerError.protocolFailure }
    return text
  }

  static func identifier(_ object: [String: Any], _ key: String) throws -> String {
    let text = try text(object, key, maximum: 256)
    guard !text.isEmpty,
      text.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 58, 95].contains($0)
      })
    else { throw WorkerError.protocolFailure }
    return text
  }

  static func header(_ object: [String: Any]) throws -> String {
    guard let version = object["version"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "1"
    else { throw WorkerError.protocolFailure }
    return try text(object, "type", maximum: 32)
  }
}

private struct WorkerStart {
  let invocationID: String
  let state: URL
  let sessions: URL
  let memory: URL
  let snippets: URL?
  let prompts: URL?
  let globalAgents: URL?
  let selection: DreamSelectedCall
  let resume: DreamResumeAction
  let batchTextBytes: Int
  let deviceKey: String?
  let projectBindings: [String: String]
  let excludedSessionIDs: Set<String>

  init(_ object: [String: Any]) throws {
    let optional = Set(object.keys).intersection([
      "deviceKey", "projectBindings", "excludedSessionIDs",
    ])
    try WorkerJSON.fields(
      object,
      Set(["version", "type", "invocationID", "roots", "selection", "resume", "batchTextBytes"])
        .union(optional))
    if let raw = object["excludedSessionIDs"] {
      guard let ids = raw as? [String], ids.count <= 64, ids == ids.sorted(),
        Set(ids).count == ids.count
      else { throw WorkerError.protocolFailure }
      for id in ids {
        let checked = try WorkerJSON.identifier(["id": id], "id")
        let alphanumeric = CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard !checked.contains(":"),
          checked.unicodeScalars.first.map({ alphanumeric.contains($0) }) == true,
          checked.unicodeScalars.last.map({ alphanumeric.contains($0) }) == true
        else { throw WorkerError.protocolFailure }
      }
      excludedSessionIDs = Set(ids)
    } else {
      excludedSessionIDs = []
    }
    deviceKey = try object["deviceKey"].map { _ in
      try WorkerJSON.text(object, "deviceKey", maximum: 64)
    }
    if object["projectBindings"] != nil {
      guard let bindings = object["projectBindings"] as? [String: String] else {
        throw WorkerError.protocolFailure
      }
      projectBindings = bindings
    } else {
      projectBindings = [:]
    }
    try MemoryScopeConfiguration.validate(deviceKey: deviceKey, projectBindings: projectBindings)
    guard let budget = object["batchTextBytes"] as? Int, !(object["batchTextBytes"] is Bool),
      (65_536...1_048_576).contains(budget)
    else { throw WorkerError.protocolFailure }
    batchTextBytes = budget
    guard try WorkerJSON.header(object) == "start",
      let roots = object["roots"] as? [String: Any],
      let selected = object["selection"] as? [String: Any]
    else { throw WorkerError.protocolFailure }
    try WorkerJSON.fields(
      roots, ["state", "sessions", "memory", "snippets", "prompts", "globalAgents"])
    try WorkerJSON.fields(selected, ["provider", "modelID", "thinkingLevel"])
    invocationID = try WorkerJSON.identifier(object, "invocationID")
    func root(_ key: String) throws -> URL {
      let path = try WorkerJSON.text(roots, key)
      guard path.hasPrefix("/") else { throw WorkerError.protocolFailure }
      return URL(fileURLWithPath: path)
    }
    state = try root("state")
    sessions = try root("sessions")
    memory = try root("memory")
    snippets = roots["snippets"] is NSNull ? nil : try root("snippets")
    prompts = roots["prompts"] is NSNull ? nil : try root("prompts")
    globalAgents = roots["globalAgents"] is NSNull ? nil : try root("globalAgents")
    selection = try DreamSelectedCall(
      provider: WorkerJSON.text(selected, "provider", maximum: 256),
      modelID: WorkerJSON.text(selected, "modelID", maximum: 256),
      thinkingLevel: WorkerJSON.text(selected, "thinkingLevel", maximum: 256))
    switch try WorkerJSON.text(object, "resume", maximum: 32) {
    case "inspectOrContinue": resume = .inspectOrContinue
    case "retryInterruptedCall": resume = .retryInterruptedCall
    case "replaceInvalidResponse": resume = .replaceInvalidResponse
    default: throw WorkerError.protocolFailure
    }
  }
}

private final class WorkerInput: @unchecked Sendable {
  static let maximumStartBytes = 65_536
  static let maximumReplyBytes = DreamSourceProtection.maximumOutputBytes * 6 + 8192
  static let maximumModelReplyBytes = 262_144 * 6 + 8192
  static let maximumProtectionRequests = 16
  static let maximumAggregateBytes =
    maximumStartBytes + maximumReplyBytes * maximumProtectionRequests + 262_144 * 6 + 8192
  private let condition = NSCondition()
  private var start: WorkerStart?
  private var request: DreamModelRequest?
  private var reply: String?
  private var protectionRequest: (id: String, digest: String, pieces: [String])?
  private var protectionReply: [String]?
  private var protectionFailure: DreamSourceProtectionError?
  private var protectionCount = 0
  private var failure: WorkerError?
  private var isStopped = false
  private var isCancelledFlag = false
  private var isCancelReceived = false
  private var isReplyReceived = false

  func launch() {
    Thread.detachNewThread { self.read() }
  }

  var isCancelled: Bool {
    condition.lock()
    defer { condition.unlock() }
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let available = Darwin.poll(&descriptor, 1, 0)
    return isCancelledFlag || failure != nil
      || (start != nil && available > 0 && descriptor.revents != 0)
  }

  var isProtocolFailure: Bool {
    condition.lock()
    defer { condition.unlock() }
    if case .protocolFailure? = failure { return true }
    return false
  }

  func awaitStart() throws -> WorkerStart {
    condition.lock()
    defer { condition.unlock() }
    while start == nil && failure == nil && !isStopped { condition.wait() }
    guard let start else { throw failure ?? WorkerError.protocolFailure }
    return start
  }

  func expect(_ request: DreamModelRequest) throws {
    condition.lock()
    defer { condition.unlock() }
    guard self.request == nil, !isCancelledFlag, failure == nil else {
      throw failure ?? WorkerError.cancelled
    }
    self.request = request
  }

  func awaitReply() throws -> DreamCompletedResponse {
    condition.lock()
    defer { condition.unlock() }
    while reply == nil && failure == nil && !isCancelledFlag { condition.wait() }
    guard failure == nil, !isCancelledFlag, let reply else {
      throw failure ?? WorkerError.cancelled
    }
    return try DreamCompletedResponse(text: reply)
  }

  func protect(_ pieces: [String], invocationID: String) throws {
    try DreamSourceProtection.requireUnchanged(pieces, check(pieces, invocationID: invocationID))
  }

  func check(_ pieces: [String], invocationID: String) throws -> [String] {
    try DreamSourceProtection.validate(
      pieces, maximumBytes: DreamSourceProtection.maximumInputBytes)
    let id = UUID().uuidString.lowercased()
    let digest = DreamSourceProtection.digest(pieces).rawValue
    condition.lock()
    guard protectionRequest == nil, request == nil, failure == nil, !isCancelledFlag else {
      condition.unlock()
      throw DreamSourceProtectionError.unavailable
    }
    guard protectionCount < Self.maximumProtectionRequests else {
      condition.unlock()
      throw DreamSourceProtectionError.requestLimit
    }
    protectionCount += 1
    protectionRequest = (id, digest, pieces)
    protectionReply = nil
    protectionFailure = nil
    condition.unlock()
    try WorkerOutput.emit(
      [
        "version": 1, "type": "sourceProtectionRequest", "invocationID": invocationID,
        "requestID": id, "inputDigest": digest, "pieces": pieces,
      ], maximum: DreamSourceProtection.maximumInputBytes * 6 + 8192)
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(10)
    while protectionReply == nil, protectionFailure == nil, failure == nil, !isCancelledFlag {
      if !condition.wait(until: deadline) {
        isCancelledFlag = true
        throw DreamSourceProtectionError.timeout
      }
    }
    guard failure == nil, !isCancelledFlag else { throw DreamSourceProtectionError.cancelled }
    if let protectionFailure { throw protectionFailure }
    guard let protectionReply else { throw DreamSourceProtectionError.invalidReply }
    protectionRequest = nil
    self.protectionReply = nil
    return protectionReply
  }

  private func consumeProtection(_ object: [String: Any]) throws {
    guard let expected = protectionRequest, protectionReply == nil, protectionFailure == nil,
      !isCancelReceived,
      try WorkerJSON.identifier(object, "requestID") == expected.id,
      try WorkerJSON.identifier(object, "inputDigest") == expected.digest
    else { throw WorkerError.protocolFailure }
    let status = try WorkerJSON.text(object, "status", maximum: 16)
    let keys: Set<String> = [
      "version", "type", "invocationID", "requestID", "inputDigest", "status",
    ]
    if status == "blocked" {
      try WorkerJSON.fields(object, keys.union(["code"]))
      let code = try WorkerJSON.text(object, "code", maximum: 32)
      guard
        [
          "not-ready", "unavailable", "timeout", "cancelled", "invalid-input", "invalid-output",
          "failed",
        ].contains(code)
      else { throw WorkerError.protocolFailure }
      protectionFailure = .blocked
    } else {
      try WorkerJSON.fields(object, keys.union(["policy", "pieces", "outputDigest"]))
      guard status == "checked",
        try WorkerJSON.text(object, "policy") == "pi-credentials/redact-v1",
        let pieces = object["pieces"] as? [String], pieces.count == expected.pieces.count
      else { throw WorkerError.protocolFailure }
      try DreamSourceProtection.validate(
        pieces, maximumBytes: DreamSourceProtection.maximumOutputBytes)
      guard
        try WorkerJSON.identifier(object, "outputDigest")
          == DreamSourceProtection.digest(pieces).rawValue
      else { throw WorkerError.protocolFailure }
      protectionReply = pieces
    }
  }

  private func consume(_ bytes: Data) throws {
    let object = try WorkerJSON.object(bytes)
    let type = try WorkerJSON.header(object)
    guard failure == nil else { throw WorkerError.protocolFailure }
    if start == nil {
      guard bytes.count <= Self.maximumStartBytes else { throw WorkerError.protocolFailure }
      start = try WorkerStart(object)
      return
    }
    guard let start,
      try WorkerJSON.identifier(object, "invocationID") == start.invocationID
    else { throw WorkerError.protocolFailure }
    if type == "cancel" {
      try WorkerJSON.fields(object, ["version", "type", "invocationID"])
      guard !isCancelReceived else { throw WorkerError.protocolFailure }
      isCancelReceived = true
      isCancelledFlag = true
      return
    }
    if type == "sourceProtectionResult" {
      try consumeProtection(object)
      return
    }
    guard protectionRequest == nil else { throw WorkerError.protocolFailure }
    guard let request, !isReplyReceived, !isCancelReceived,
      type == "modelResponse" || type == "modelFailure"
    else { throw WorkerError.protocolFailure }
    try WorkerJSON.fields(
      object,
      [
        "version", "type", "invocationID", "requestID", "runID", "inputHash", "contextHash",
        "requestHash",
        type == "modelResponse" ? "text" : "category",
      ])
    for (key, expected) in [
      ("requestID", request.runID + ":" + request.requestHash.rawValue),
      ("runID", request.runID), ("inputHash", request.inputHash.rawValue),
      ("contextHash", request.contextHash.rawValue), ("requestHash", request.requestHash.rawValue),
    ] {
      guard try WorkerJSON.identifier(object, key) == expected else {
        throw WorkerError.protocolFailure
      }
    }
    isReplyReceived = true
    if type == "modelResponse" {
      guard let text = object["text"] as? String, !text.isEmpty,
        text.utf8.count <= 262_144
      else { throw WorkerError.protocolFailure }
      reply = text
    } else {
      let category = try WorkerJSON.text(object, "category", maximum: 16)
      guard ["failed", "cancelled", "incomplete"].contains(category) else {
        throw WorkerError.protocolFailure
      }
      failure = category == "cancelled" ? .cancelled : .modelFailure
      if category == "cancelled" { isCancelledFlag = true }
    }
  }

  private func isInputFinished(buffer: inout [UInt8], frame: inout Data, total: inout Int) throws
    -> Bool
  {
    condition.lock()
    var isValid = false
    defer {
      if !isValid {
        failure = .protocolFailure
        isCancelledFlag = true
      }
      condition.broadcast()
      condition.unlock()
    }
    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
    if count < 0 {
      if errno == EINTR {
        isValid = true
        return false
      }
      throw WorkerError.protocolFailure
    }
    if count == 0 {
      isCancelledFlag = true
      isStopped = true
      if !frame.isEmpty || start == nil { failure = .protocolFailure }
      isValid = true
      return true
    }
    guard total <= Self.maximumAggregateBytes - count else { throw WorkerError.protocolFailure }
    total += count
    for byte in buffer.prefix(count) {
      if byte == 10 {
        try consume(frame)
        frame.removeAll(keepingCapacity: true)
      } else {
        if start != nil && protectionRequest == nil && (request == nil || isReplyReceived) {
          isCancelledFlag = true
        }
        let maximum =
          start == nil
          ? Self.maximumStartBytes
          : (protectionRequest == nil ? Self.maximumModelReplyBytes : Self.maximumReplyBytes)
        guard frame.count < maximum else { throw WorkerError.protocolFailure }
        frame.append(byte)
      }
    }
    isValid = true
    return false
  }

  private func read() {
    var frame = Data()
    var total = 0
    var buffer = [UInt8](repeating: 0, count: 4096)
    do {
      while true {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, -1)
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0 else { throw WorkerError.protocolFailure }
        let isFinished = try isInputFinished(buffer: &buffer, frame: &frame, total: &total)
        if isFinished { return }
      }
    } catch {
      condition.lock()
      failure = .protocolFailure
      isCancelledFlag = true
      isStopped = true
      condition.broadcast()
      condition.unlock()
    }
  }
}

private enum WorkerOutput {
  static func emit(_ object: [String: Any], maximum: Int) throws {
    let bytes = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    guard bytes.count <= maximum else { throw WorkerError.protocolFailure }
    try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
  }

  static func selection(_ selection: DreamSelectedCall) -> [String: Any] {
    [
      "provider": selection.provider, "modelID": selection.modelID,
      "thinkingLevel": selection.thinkingLevel,
    ]
  }

  static func sources(_ sources: [PrimaryTextID]) -> [[String: Any]] {
    sources.map {
      [
        "sessionID": $0.citation.session, "entryID": $0.citation.entry,
        "partIndex": $0.part,
      ]
    }
  }

  static func proposals(_ proposals: [DreamProposalReceipt]) -> [[String: Any]] {
    proposals.map {
      [
        "ref": $0.ref, "commit": $0.commit, "base": $0.base, "path": $0.path,
        "sources": sources($0.sources), "contradictions": $0.contradictions,
      ]
    }
  }

  static func final(
    _ invocationID: String, _ result: DreamTransactionResult?, reason: String? = nil,
    detail: String? = nil, isBusy: Bool = false, isProtocolFailure: Bool = false
  ) throws {
    var object: [String: Any] = [
      "version": 1, "type": "final", "invocationID": invocationID,
      "status": isBusy ? "busy" : "blocked", "generation": "0", "runID": NSNull(),
      "base": NSNull(), "proposals": [], "notes": [], "isBacklog": false,
      "isRecovered": false, "reason": reason as Any? ?? NSNull(),
      "detail": detail.map {
        String(
          decoding: $0.replacingOccurrences(of: "\0", with: "\\u{0}").utf8.prefix(1020),
          as: UTF8.self)
      } as Any? ?? NSNull(),
      "unfinishedTails": 0,
    ]
    if let result {
      switch result {
      case .completed(let report):
        object["status"] = "completed"
        object["generation"] = String(report.generation)
        object["runID"] = report.runID
        object["base"] = report.approvedBase
        object["proposals"] = proposals(report.proposals)
        object["notes"] = report.notes.map { note -> [String: Any] in
          [
            "kind": note.kind, "sources": sources(note.sources), "explanation": note.explanation,
            "reasonCode": note.reasonCode as Any? ?? NSNull(),
            "ownerReference": note.ownerReference as Any? ?? NSNull(),
            "contradictions": note.contradictions,
          ]
        }
        object["isBacklog"] = report.isBacklog
        object["isRecovered"] = report.isRecovered
      case .pending(let report):
        object["status"] = isProtocolFailure ? "blocked" : "pending"
        object["generation"] = String(report.generation)
        object["runID"] = report.runID
        object["base"] = report.approvedBase
        object["proposals"] = proposals(report.proposals)
        object["reason"] = isProtocolFailure ? "protocolFailure" : report.reason.rawValue
        if !isProtocolFailure, let error = report.validationError {
          object["detail"] = String(describing: error)
        }
      case .noNewRecords(let generation, let tails):
        object["status"] = "noNewRecords"
        object["generation"] = String(generation)
        object["unfinishedTails"] = tails.count
      }
    }
    try emit(object, maximum: 32 * 1_048_576 * 6 + 65_536)
  }
}

func executeDreamWorker(arguments: [String]) -> Int32 {
  signal(SIGPIPE, SIG_IGN)
  let input = WorkerInput()
  input.launch()
  var invocationID: String?
  var isFinalAttempted = false
  do {
    guard arguments == ["dream-worker"] else { throw WorkerError.protocolFailure }
    let start = try input.awaitStart()
    invocationID = start.invocationID
    guard !input.isCancelled else { throw WorkerError.cancelled }
    let store = try DreamRunStore(
      stateRoot: start.state, sessionsRoot: start.sessions, memoryRepository: start.memory,
      strippingRoots: [start.snippets, start.prompts].compactMap { $0 },
      globalAgents: start.globalAgents, deviceKey: start.deviceKey,
      projectBindings: start.projectBindings, isCancelled: { input.isCancelled })
    var coverageFrame: [String: Any]?
    var backlog: DreamBacklog?
    let result = try store.run(
      selection: start.selection, resume: start.resume,
      sourceRoles: DreamSourceRoles(
        isSnippetsPresent: start.snippets != nil, isPromptsPresent: start.prompts != nil),
      excludedSessionIDs: start.excludedSessionIDs,
      protect: { try input.protect($0, invocationID: start.invocationID) },
      prepare: { progress, sources in
        guard !input.isCancelled else { throw WorkerError.cancelled }
        return try SessionReader(
          sessions: sources.sessions, snippets: sources.snippets, prompts: sources.prompts
        )
        .prepareProtected(
          progress: progress, limits: DreamInputLimits(maximumBatchBytes: start.batchTextBytes),
          protect: { try input.protect($0, invocationID: start.invocationID) },
          admit: { try input.check($0, invocationID: start.invocationID) },
          priorViews: sources.admittedViews, excludedSessionIDs: start.excludedSessionIDs,
          backlog: { backlog = $0 }, isCancelled: { input.isCancelled })
      },
      call: { request in
        try input.expect(request)
        try WorkerOutput.emit(
          [
            "version": 1, "type": "modelRequest", "invocationID": start.invocationID,
            "requestID": request.runID + ":" + request.requestHash.rawValue,
            "runID": request.runID, "generation": String(request.generation),
            "inputHash": request.inputHash.rawValue, "contextHash": request.contextHash.rawValue,
            "requestHash": request.requestHash.rawValue,
            "selection": WorkerOutput.selection(request.selection),
            "systemPrompt": request.systemPrompt,
            "messages": request.messages.map {
              [
                "role": $0.role.rawValue, "text": $0.text,
                "timestampMilliseconds": $0.timestampMilliseconds,
              ] as [String: Any]
            },
          ], maximum: 32 * 1_048_576 * 6 + 65_536)
        do {
          return try input.awaitReply()
        } catch WorkerError.cancelled {
          throw CancellationError()
        }
      },
      observe: { progress, batch, isRepeated, estimate in
        let frame: [String: Any] = [
          "version": 1, "type": "progress", "invocationID": start.invocationID,
          "backlogBytes": backlog.map { $0.backlogBytes as Any } ?? NSNull(),
          "backlogLimitBytes": backlog.map { _ in SessionReader.dreamBacklogBytes as Any }
            ?? NSNull(),
          "undreamtBytes": backlog.map { $0.undreamtBytes as Any } ?? NSNull(),
          "nextBytes": backlog.map { $0.nextBytes as Any } ?? NSNull(),
          "plannedBytes": batch.keptBytes, "completedBytes": 0,
          "repeatedRecords": isRepeated
            ? batch.exactSourceRecords.filter {
              if case .primaryEvidence = $0.disposition { return true }
              return false
            }.count : 0,
          "estimateSeconds": estimate.map { $0 as Any } ?? NSNull(),
        ]
        coverageFrame = frame
        try WorkerOutput.emit(frame, maximum: 8192)
      })
    if var frame = coverageFrame, case .completed = result {
      frame["completedBytes"] = frame["plannedBytes"]
      try WorkerOutput.emit(frame, maximum: 8192)
    }
    isFinalAttempted = true
    if case .noNewRecords = result, input.isCancelled {
      try WorkerOutput.final(
        start.invocationID, nil,
        reason: input.isProtocolFailure ? "protocolFailure" : "cancelled")
    } else {
      try WorkerOutput.final(start.invocationID, result, isProtocolFailure: input.isProtocolFailure)
    }
    return 0
  } catch {
    if let invocationID, !isFinalAttempted {
      do {
        try WorkerOutput.final(
          invocationID, nil,
          reason: input.isProtocolFailure
            ? "protocolFailure"
            : ((error as? WorkerError) == .cancelled
              ? "cancelled"
              : (error as? DreamSourceProtectionError).map {
                "sourceProtection:" + String(describing: $0)
              } ?? "workerFailure"),
          detail: [
            "no snippet bodies in --snippets", "no prompt templates in --prompts",
            "unsafe dream state",
          ].contains(
            String(describing: error)) ? String(describing: error) : nil,
          isBusy: (error as? DreamRunError) == .busy)
        return 0
      } catch {}
    }
    try? FileHandle.standardError.write(
      contentsOf: Data(
        "dream-worker: \(input.isProtocolFailure || (error as? WorkerError) == .protocolFailure ? "protocolFailure" : "workerFailure")\n"
          .utf8))
    return 1
  }
}
