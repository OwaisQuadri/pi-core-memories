import Foundation

package struct MemoryScopeConfiguration: Codable, Sendable {
  package var deviceKey: String?
  package var projectBindings: [String: String]

  package init(deviceKey: String?, projectBindings: [String: String]) {
    self.deviceKey = deviceKey
    self.projectBindings = projectBindings
  }

  package static func validate(deviceKey: String?, projectBindings: [String: String]) throws {
    guard deviceKey.map({ MemoryDocument.isMatch(#"\A[0-9a-f]{64}\z"#, $0) }) ?? true,
      projectBindings.count <= 64,
      projectBindings.allSatisfy({ path, key in
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0")
          && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
          && MemoryDocument.isMatch(#"\A[0-9a-f]{64}\z"#, key)
      }), try DreamRunEncoding.encode(projectBindings).count <= 65_536
    else { throw MemoryError("invalid device key or bounded local project bindings") }
  }

  static func paths(projectKeys: [String], deviceKey: String?) -> [String] {
    var paths = ["MEMORY.md"] + projectKeys.map { "projects/\($0).md" }
    if let deviceKey {
      paths += ["devices/\(deviceKey)/MEMORY.md"]
      paths += projectKeys.map { "devices/\(deviceKey)/projects/\($0).md" }
    }
    return paths.sorted()
  }

  package static func label(path: String, deviceKey: String?) -> String {
    guard let scope = DreamMemoryScope(path: path) else { return path }
    switch scope {
    case .global: return "Global"
    case .project(let key): return "Project \(key.prefix(10))"
    case .device(let key): return key == deviceKey ? "This device" : "Device \(key.prefix(10))"
    case .deviceProject(let device, let project):
      let deviceLabel = device == deviceKey ? "This device" : "Device " + device.prefix(10)
      return "\(deviceLabel) · Project \(project.prefix(10))"
    }
  }
}

package struct MemoryConfiguration: Codable, Sendable {
  package var schemaVersion = 1
  package var settings: MemoryAppSettings
  package var roots: DreamControlRoots?
  package var journal: String
  package var reviewState: String
  package var diagnostics: String
  package var deviceKey: String?
  package var projectBindings: [String: String] = [:]

  package static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".config/pi-core-memories/config.json")
  }

  package static var defaults: Self {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return Self(
      settings: .defaults, journal: home + "/.local/state/pi-core-memories-drafts",
      reviewState: home + "/.local/state/pi-core-memories-review",
      diagnostics: home + "/.local/state/pi-core-memories-control")
  }

  package var memoryURL: URL {
    URL(
      fileURLWithPath: roots?.memory ?? ProcessInfo.processInfo.environment["PI_CORE_MEMORIES_REPO"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/pi-core-memories")
  }

  package var stateURL: URL {
    URL(
      fileURLWithPath: roots?.state ?? FileManager.default.homeDirectoryForCurrentUser.path
        + "/.local/state/pi-core-memories")
  }

  package static func load(from url: URL = defaultURL) throws -> Self {
    guard FileManager.default.fileExists(atPath: url.path) else {
      guard url.path == defaultURL.path else {
        throw MemoryError("Selected configuration file does not exist")
      }
      return defaults
    }
    let root = try DreamStateDirectory.openRoot(url.deletingLastPathComponent(), isCreating: false)
    let value = try JSONDecoder().decode(
      Self.self, from: root.read(url.lastPathComponent, maximum: 262_144))
    try value.validate()
    return value
  }

  package func save(to url: URL = defaultURL) throws {
    try validate()
    let root = try DreamStateDirectory.openRoot(url.deletingLastPathComponent())
    try root.installReviewFile(
      DreamRunEncoding.encode(self), name: url.lastPathComponent, isReplacing: true)
  }

  package mutating func setupDevice() {
    if deviceKey == nil { deviceKey = SourceDigest(bytes: Data(UUID().uuidString.utf8)).rawValue }
  }

  package func reviewSources() throws -> DreamRunStore {
    try reviewSources(stateRoot: stateURL, memoryRepository: memoryURL)
  }

  package func reviewSources(stateRoot: URL, memoryRepository: URL) throws -> DreamRunStore {
    let root = try DreamStateDirectory.openRoot(stateRoot, isCreating: false)
    let bytes = try root.read("root.json", maximum: 1_048_576)
    guard let saved = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      saved["schemaVersion"] as? Int == 2,
      let sessions = saved["sessions"] as? String, let memory = saved["memory"] as? String,
      let stripping = saved["stripping"] as? [String]
    else { throw DreamRunError.corruption }
    let original = saved["originalRoots"] as? [String] ?? ([sessions, memory] + stripping)
    guard original.count == 2 + stripping.count else { throw DreamRunError.corruption }
    guard let activeRepository = try MemoryStore.projectBindingDirectory(cwd: memoryRepository),
      activeRepository
        == (try MemoryStore.projectBindingDirectory(cwd: URL(fileURLWithPath: original[1])))
    else {
      throw MemoryError(
        "Saved dream review belongs to another memory repository. Select its matching profile.")
    }
    if let roots {
      return try DreamRunStore(
        stateRoot: stateRoot, sessionsRoot: URL(fileURLWithPath: roots.sessions),
        memoryRepository: memoryRepository,
        strippingRoots: [roots.snippets, roots.prompts].compactMap { $0 }.map {
          URL(fileURLWithPath: $0)
        },
        globalAgents: roots.globalAgents.map { URL(fileURLWithPath: $0) }, deviceKey: deviceKey,
        projectBindings: projectBindings)
    }
    return try DreamRunStore(
      stateRoot: stateRoot, sessionsRoot: URL(fileURLWithPath: original[0]),
      memoryRepository: URL(fileURLWithPath: original[1]),
      strippingRoots: original.dropFirst(2).map { URL(fileURLWithPath: $0) },
      globalAgents: (saved["globalAgents"] as? String).map { URL(fileURLWithPath: $0) },
      deviceKey: deviceKey, projectBindings: projectBindings)
  }

  package func validate() throws {
    try settings.validate()
    try MemoryScopeConfiguration.validate(deviceKey: deviceKey, projectBindings: projectBindings)
    guard schemaVersion == 1,
      [journal, reviewState, diagnostics, memoryURL.path, stateURL.path].allSatisfy({
        $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096
      })
    else { throw DreamRunError.unsafeState }
  }
}
