import Darwin
import Foundation

package struct MemoryAppSettings: Codable, Sendable {
  package var schemaVersion = 1
  package var piExecutable: String
  package var agentDirectory: String
  package var provider: String?
  package var modelID: String?
  package var thinkingLevel: String?

  package static var defaults: Self {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return Self(piExecutable: "/opt/homebrew/bin/pi", agentDirectory: home + "/.pi/agent")
  }

  package static func load(from directory: URL) throws -> Self {
    guard FileManager.default.fileExists(atPath: directory.path) else { return defaults }
    let root = try DreamStateDirectory.openRoot(directory, isCreating: false)
    guard try root.isPresent("settings.json") else { return defaults }
    let value = try JSONDecoder().decode(Self.self, from: root.read("settings.json", maximum: 65_536))
    try value.validate()
    return value
  }

  package func save(to directory: URL) throws {
    try validate()
    let root = try DreamStateDirectory.openRoot(directory)
    try root.installReviewFile(DreamRunEncoding.encode(self), name: "settings.json", isReplacing: true)
  }

  package func validate() throws {
    guard schemaVersion == 1, piExecutable.hasPrefix("/"), agentDirectory.hasPrefix("/"),
      [piExecutable, agentDirectory].allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }),
      [provider, modelID, thinkingLevel].compactMap({ $0 }).allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      }),
      thinkingLevel.map({ ["off", "minimal", "low", "medium", "high", "xhigh"].contains($0) }) ?? true
    else { throw MemoryError("invalid Pi executable, agent directory, or explicit selection") }
  }
}

package struct DreamControlRoots: Codable, Sendable {
  package let state: String
  package let sessions: String
  package let memory: String
  package let snippets: String?
  package let prompts: String?
  package let globalAgents: String?

  private enum CodingKeys: String, CodingKey { case state, sessions, memory, snippets, prompts, globalAgents }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(state, forKey: .state)
    try container.encode(sessions, forKey: .sessions)
    try container.encode(memory, forKey: .memory)
    try container.encode(snippets, forKey: .snippets)
    try container.encode(prompts, forKey: .prompts)
    try container.encode(globalAgents, forKey: .globalAgents)
  }
}

package enum DreamControlOperation: String, Codable, Sendable { case start, all, retry, replace }

package final class DreamControl: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var input: FileHandle?
  private var isReady = false
  private var cancellationDate: Date?
  package let invocationID = UUID()

  package init() {}

  package func cancel() {
    lock.lock()
    defer { lock.unlock() }
    if cancellationDate == nil { cancellationDate = Date() }
    if isReady {
      try? sendLocked(["id": "cancel", "type": "prompt", "message": "/memory-dream-cancel"])
    }
  }

  package func run(
    operation: DreamControlOperation, settings: MemoryAppSettings, roots: DreamControlRoots?,
    diagnostics: URL, deviceKey: String? = nil, projectBindings: [String: String] = [:],
    onEvent: @escaping @Sendable (Data) -> Void
  ) throws {
    try settings.validate()
    try MemoryScopeConfiguration.validate(deviceKey: deviceKey, projectBindings: projectBindings)
    if let roots {
      guard [roots.state, roots.sessions, roots.memory, roots.snippets, roots.prompts, roots.globalAgents]
        .compactMap({ $0 }).allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") })
      else { throw DreamRunError.unsafeState }
    }
    let extensionURL = URL(fileURLWithPath: settings.agentDirectory)
      .appendingPathComponent("extensions/core-memories/control.ts")
    _ = try canonicalExistingFile(extensionURL)
    let journal = try DreamStateDirectory.openRoot(diagnostics)
    let invocation = try journal.child(invocationID.uuidString, isCreating: true)
    var request: [String: Any] = [
      "operation": operation.rawValue,
      "roots": try roots.map { try JSONSerialization.jsonObject(with: DreamRunEncoding.encode($0)) } ?? NSNull(),
    ]
    if let deviceKey { request["deviceKey"] = deviceKey }
    if !projectBindings.isEmpty { request["projectBindings"] = projectBindings }
    try invocation.installReviewFile(
      JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "invocationID": invocationID.uuidString,
        "operation": operation.rawValue,
        "requestedSettings": try JSONSerialization.jsonObject(with: DreamRunEncoding.encode(settings)),
        "request": request,
      ], options: [.sortedKeys]), name: "request.json")
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: settings.piExecutable)
    var arguments = [
      "--mode", "rpc", "--no-session", "--no-mcp", "--no-tools", "--no-skills",
      "--no-prompt-templates", "--no-context-files", "-e", extensionURL.path,
    ]
    if let provider = settings.provider { arguments += ["--provider", provider] }
    if let modelID = settings.modelID { arguments += ["--model", modelID] }
    if let thinking = settings.thinkingLevel { arguments += ["--thinking", thinking] }
    process.arguments = arguments
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    process.environment = ProcessInfo.processInfo.environment
    lock.lock()
    guard self.process == nil, cancellationDate == nil else {
      lock.unlock()
      throw CancellationError()
    }
    self.process = process
    self.input = stdin.fileHandleForWriting
    lock.unlock()
    let exit: DispatchGroup
    do { exit = try launch(process) } catch {
      lock.lock(); self.process = nil; self.input = nil; lock.unlock()
      throw error
    }
    try? stdin.fileHandleForReading.close()
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    defer {
      lock.lock()
      isReady = false
      input = nil
      self.process = nil
      try? stdin.fileHandleForWriting.close()
      lock.unlock()
      if exit.wait(timeout: .now() + 3) == .timedOut {
        process.terminate()
        if exit.wait(timeout: .now() + 2) == .timedOut { _ = kill(process.processIdentifier, SIGKILL); exit.wait() }
      }
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
    }
    var eventCount = 0
    var terminalError: String?
    do {
      try send(["id": "commands", "type": "get_commands"])
      var buffer = Data()
      var errorBytes = Data()
      var isVerified = false
      var isTerminal = false
      var isPromptComplete = false
      let started = Date()
      while !isPromptComplete {
        lock.lock(); let cancelled = cancellationDate; lock.unlock()
        if let cancelled, Date().timeIntervalSince(cancelled) > 10 { throw CancellationError() }
        if !isVerified && Date().timeIntervalSince(started) > 15 { throw MemoryError("Pi command handshake timed out") }
        var descriptors = [
          pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
          pollfd(fd: stderr.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
        ]
        let polled = poll(&descriptors, 2, 200)
        if polled < 0, errno == EINTR { continue }
        guard polled >= 0 else { throw MemoryError("Pi RPC read failed") }
        if descriptors[1].revents & Int16(POLLIN) != 0 {
          let bytes = try readAvailable(stderr.fileHandleForReading.fileDescriptor, maximum: 16_384)
          guard bytes.count <= 262_144 - errorBytes.count else { throw DreamRunError.limitExceeded }
          errorBytes.append(bytes)
        }
        if descriptors[0].revents & Int16(POLLIN) != 0 {
          let bytes = try readAvailable(stdout.fileHandleForReading.fileDescriptor, maximum: 65_536)
          guard !bytes.isEmpty else { throw MemoryError("Pi RPC closed before prompt completion") }
          buffer.append(bytes)
          while let boundary = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<boundary])
            buffer.removeSubrange(...boundary)
            guard line.count <= 1_048_576, String(data: line, encoding: .utf8) != nil,
              let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { throw MemoryError("invalid bounded Pi RPC frame") }
            if frame["type"] as? String == "response", frame["id"] as? String == "commands" {
              guard frame["success"] as? Bool == true,
                let data = frame["data"] as? [String: Any], let commands = data["commands"] as? [[String: Any]],
                commands.contains(where: { $0["name"] as? String == "memory-dream-control" }),
                commands.contains(where: { $0["name"] as? String == "memory-dream-cancel" }), !isVerified
              else { throw MemoryError("Pi did not register the memory dream controls; no prompt sent") }
              isVerified = true
              lock.lock(); isReady = true; let isCancelled = cancellationDate != nil; lock.unlock()
              if isCancelled { throw CancellationError() }
              let json = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
              try send(["id": "dream", "type": "prompt", "message": "/memory-dream-control " + String(decoding: json, as: UTF8.self)])
            } else if frame["type"] as? String == "extension_ui_request", frame["method"] as? String == "notify",
              let message = frame["message"] as? String, let bytes = message.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              event["version"] as? Int == 1, event["type"] as? String == "core-memory-control"
            {
              guard isVerified, eventCount < 10_000, !isTerminal,
                let kind = event["event"] as? String,
                ["selection", "phase", "progress", "batchReport", "report", "error"].contains(kind)
              else { throw MemoryError("unexpected Pi dream control event") }
              eventCount += 1
              try invocation.installReviewFile(bytes, name: "event-\(eventCount).json")
              onEvent(bytes)
              if kind == "report" || kind == "error" { isTerminal = true }
              if kind == "error" { terminalError = event["detail"] as? String ?? "Pi dream failed" }
            } else if frame["type"] as? String == "response", frame["id"] as? String == "dream" {
              guard frame["success"] as? Bool == true, isTerminal else {
                throw MemoryError("Pi prompt finished without a terminal dream report")
              }
              isPromptComplete = true
            }
          }
          guard buffer.count <= 1_048_576 else { throw DreamRunError.limitExceeded }
        }
        if exit.wait(timeout: .now()) == .success && !isPromptComplete {
          throw MemoryError("Pi exited before completing dream control (status \(process.terminationStatus))")
        }
      }
      if !errorBytes.isEmpty { try invocation.installReviewFile(errorBytes, name: "stderr.txt") }
      if let terminalError { throw MemoryError(terminalError) }
    } catch {
      try? invocation.installReviewFile(
        JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "detail": String(describing: error)]),
        name: "error.json")
      throw error
    }
  }

  private func readAvailable(_ descriptor: Int32, maximum: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: maximum)
    let count = Darwin.read(descriptor, &bytes, maximum)
    guard count >= 0 else { throw MemoryError("Pi RPC read failed") }
    return Data(bytes.prefix(count))
  }

  private func send(_ object: [String: Any]) throws {
    lock.lock(); defer { lock.unlock() }
    try sendLocked(object)
  }

  private func sendLocked(_ object: [String: Any]) throws {
    guard let input else { throw MemoryError("owned Pi process is not connected") }
    try input.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
  }
}
