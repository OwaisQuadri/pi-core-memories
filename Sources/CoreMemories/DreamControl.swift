import Foundation

package struct MemoryAppSettings: Codable, Sendable {
  package var schemaVersion = 1
  package var piExecutable: String
  package var agentDirectory: String
  package var provider: String?
  package var modelID: String?
  package var thinkingLevel: String?
  package var controlExtension: String?

  package static var defaults: Self {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let paths =
      (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
      + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    let executable =
      paths.map { URL(fileURLWithPath: $0).appendingPathComponent("pi").path }
      .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    return Self(
      piExecutable: executable,
      agentDirectory: ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"] ?? home
        + "/.pi/agent")
  }

  package func validate() throws {
    guard schemaVersion == 1, piExecutable.hasPrefix("/"), agentDirectory.hasPrefix("/"),
      [piExecutable, agentDirectory].allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }),
      [provider, modelID, thinkingLevel].compactMap({ $0 }).allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 256
          && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      }),
      thinkingLevel.map({
        ["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains($0)
      }) ?? true
    else { throw MemoryError("invalid Pi executable, agent directory, or explicit selection") }
    guard provider == nil || modelID != nil else {
      throw MemoryError("an explicit Pi provider requires an explicit model")
    }
    if let controlExtension {
      guard controlExtension.hasPrefix("/"), !controlExtension.contains("\0"),
        controlExtension.utf8.count <= 4096
      else {
        throw MemoryError("invalid Pi control extension path")
      }
    }
  }
}

package struct DreamControlRoots: Codable, Sendable {
  package var state: String
  package var sessions: String
  package var memory: String
  package var snippets: String?
  package var prompts: String?
  package var globalAgents: String?

  package init(
    state: String, sessions: String, memory: String, snippets: String?, prompts: String?,
    globalAgents: String?
  ) {
    self.state = state
    self.sessions = sessions
    self.memory = memory
    self.snippets = snippets
    self.prompts = prompts
    self.globalAgents = globalAgents
  }

  private enum CodingKeys: String, CodingKey {
    case state, sessions, memory, snippets, prompts, globalAgents
  }

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
