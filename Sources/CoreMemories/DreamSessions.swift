import CryptoKit
import Darwin
import Foundation

public struct Citation: Codable, Hashable, Sendable {
  public let session: String
  public let entry: String

  public var reference: String { "pi:\(session)#\(entry)" }
}

public struct SessionHeader: Codable, Sendable {
  public let id: String
  public let cwd: String
  public let timestamp: Date
  public let parentSession: String?
  public let name: String?
}

public enum SessionClass: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
  case primary, child, infrastructure, unreadable
}

public enum ChildMarker: String, Codable, Sendable, CodingKeyRepresentable {
  case parentSession, agentName
}

public struct EntryWindow: Codable, Sendable, Equatable {
  public let filesModifiedAfter: Date
  public let entryFloor: Date?
  public let upper: Date

  public init(filesModifiedAfter: Date, entryFloor: Date?, upper: Date) {
    self.filesModifiedAfter = filesModifiedAfter
    self.entryFloor = entryFloor
    self.upper = upper
  }

  public func isNew(_ timestamp: Date) -> Bool {
    (entryFloor.map { timestamp > $0 } ?? true) && timestamp <= upper
  }
}

public enum HumanEvidence: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
  case typed, typedSkillArguments, answered, picked
}

public struct HumanUtterance: Codable, Sendable {
  public let citation: Citation
  public let timestamp: Date
  public let evidence: HumanEvidence
  public let text: String
  public let question: String?
  public let agentContext: String?
  public let projectKey: String?
}

public enum AgentSource: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
  case primaryText, childText, childFinalText, subagentReport, orchestration
}

public struct AgentStatement: Codable, Sendable {
  public let citation: Citation
  public let source: AgentSource
  public let text: String
  public let projectKey: String?
}

public struct SubagentExchange: Codable, Sendable {
  public let request: Citation
  public let agentId: String?
  public let childSession: String?
  public let subagentType: String?
  public let description: String?
  public let prompt: String
  public var report: AgentStatement?
  public let projectKey: String?
}

public struct PathTouch: Codable, Hashable, Sendable {
  public let projectKey: String?
  public let projectAlias: String
  public let path: String
  public let tool: String
  public let session: String
}

public enum StuckKind: String, Codable, Sendable {
  case repeatedToolError, repeatedCommand, abortedTurn, lengthStop
}

public struct StuckSignal: Codable, Sendable {
  public let kind: StuckKind
  public let citations: [Citation]
  public let excerpt: String
  public let projectKey: String?
}

public struct ReaderCounts: Codable, Sendable {
  public var human: [HumanEvidence: Int] = [:]
  public var unknownMarkup = 0
  public var skillOnly = 0
  public var snippetOnly = 0
  public var acknowledgements = 0
  public var childAnswers = 0
  public var customMessages = 0
  public var undecodableLines = 0
  public var inFlightLines = 0
  public var untimedEntries = 0
  public var bytesRead = 0

  mutating func add(_ other: ReaderCounts) {
    human.merge(other.human, uniquingKeysWith: +)
    unknownMarkup += other.unknownMarkup
    skillOnly += other.skillOnly
    snippetOnly += other.snippetOnly
    acknowledgements += other.acknowledgements
    childAnswers += other.childAnswers
    customMessages += other.customMessages
    undecodableLines += other.undecodableLines
    inFlightLines += other.inFlightLines
    untimedEntries += other.untimedEntries
    bytesRead += other.bytesRead
  }
}

public struct PrimaryDigest: Codable, Sendable {
  public let header: SessionHeader
  public let path: String
  public let projectKey: String?
  public let projectAlias: String
  public let human: [HumanUtterance]
  public let agent: [AgentStatement]
  public var exchanges: [SubagentExchange]
  public let paths: [PathTouch]
  public let stuck: [StuckSignal]
  public let counts: ReaderCounts
}

public struct ChildDigest: Codable, Sendable {
  public let header: SessionHeader
  public let path: String
  public let marker: ChildMarker
  public let projectKey: String?
  public let projectAlias: String
  public let orchestration: [AgentStatement]
  public let agent: [AgentStatement]
  public let finalText: AgentStatement?
  public var exchanges: [SubagentExchange]
  public let paths: [PathTouch]
  public let stuck: [StuckSignal]
  public let counts: ReaderCounts
}

public enum SessionDigest: Codable, Sendable {
  case primary(PrimaryDigest)
  case child(ChildDigest)
  case skipped(path: String, sessionClass: SessionClass, name: String?)

  var path: String {
    switch self {
    case .primary(let digest): digest.path
    case .child(let digest): digest.path
    case .skipped(let path, _, _): path
    }
  }

  var sessionClass: SessionClass {
    switch self {
    case .primary: .primary
    case .child: .child
    case .skipped(_, let sessionClass, _): sessionClass
    }
  }

  var exchanges: [SubagentExchange] {
    get {
      switch self {
      case .primary(let digest): digest.exchanges
      case .child(let digest): digest.exchanges
      case .skipped: []
      }
    }
    set {
      switch self {
      case .primary(var digest):
        digest.exchanges = newValue
        self = .primary(digest)
      case .child(var digest):
        digest.exchanges = newValue
        self = .child(digest)
      case .skipped: break
      }
    }
  }
}

public enum HumanText: Equatable, Sendable {
  case human(String, HumanEvidence)
  case unknownMarkup, skillOnly, snippetOnly, acknowledgement, empty
}

public struct Census: Codable, Sendable {
  public let window: EntryWindow
  public let files: Int
  public let sessions: [SessionClass: Int]
  public let infrastructure: [String: Int]
  public let childMarkers: [ChildMarker: Int]
  public let folders: [SessionClass: [String: Int]]
  public let counts: ReaderCounts
  public let agent: [AgentSource: Int]
  public let exchanges: Int
  public let pathTouches: Int
  public let stuckSignals: Int
  public let projectsResolved: Int
  public let projectsViaParent: Int
  public let projectsUnresolved: Int
  public let isSnippetsLoaded: Bool
  public let isPromptsLoaded: Bool
  public let seconds: Double
  public let samples: [HumanEvidence: [String]]
}

public struct ProjectKeys: Sendable {
  private let environment: [String: String]
  private var cache: [String: (key: String?, isViaParent: Bool)] = [:]
  var resolved = 0
  var viaParent = 0
  var unresolved = 0

  public init(environment: [String: String]) {
    self.environment = environment
  }

  public mutating func key(cwd: String, parentPath: String?) -> (
    key: String?, alias: String, isViaParent: Bool
  ) {
    let folder = isDirectory(cwd) ? cwd : cwd + "\n" + (parentPath ?? "")
    let found = cache[folder] ?? resolve(cwd: cwd, parentPath: parentPath)
    cache[folder] = found
    if found.key == nil {
      unresolved += 1
    } else if found.isViaParent {
      viaParent += 1
    } else {
      resolved += 1
    }
    return (found.key, URL(fileURLWithPath: cwd).lastPathComponent, found.isViaParent)
  }

  private func resolve(cwd: String, parentPath: String?) -> (key: String?, isViaParent: Bool) {
    if isDirectory(cwd) { return (projectKey(cwd), false) }
    var next = parentPath
    for _ in 0..<5 {
      guard let path = next,
        let lines = try? SessionReader.firstLines(of: URL(fileURLWithPath: path), count: 1),
        let header = SessionReader.header(lines)
      else { break }
      if isDirectory(header.cwd) { return (projectKey(header.cwd), true) }
      next = header.parentSession
    }
    return (nil, false)
  }

  private func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func projectKey(_ path: String) -> String? {
    try? MemoryStore.projectKey(cwd: URL(fileURLWithPath: path), environment: environment)
  }
}

private struct ClassificationRule: Sendable {
  let sessionClass: SessionClass
  let marker: ChildMarker?
  let matches: @Sendable (SessionHeader) -> Bool
}

private struct FolderRule: Sendable {
  let kind: String
  let marker: String
}

public struct SessionReader: Sendable {
  public static let infrastructurePrefixes = ["om-observer-", "om-consolidator-", "comment-shape-"]
  public static let primaryTextMinimum = 200
  public static let childTextMinimum = 400
  static let promptLimit = 2_000
  static let textLimit = 1_500
  static let contextLimit = 600
  static let excerptLimit = 300
  static let acknowledgements: Set<String> = [
    "continue", "ok", "okay", "yes", "y", "go", "proceed", "k",
  ]
  static let injectedEnvelopes = [
    #"<file name="[^"]*">[\s\S]*?</file>"#,
    #"<persistent-memory-recall>[\s\S]*?</persistent-memory-recall>"#,
  ].map { try! NSRegularExpression(pattern: $0) }
  static let pathExtensions = [
    ".md", ".swift", ".ts", ".rs", ".toml", ".json", ".zsh", ".sh", ".py",
  ]

  private static let classificationRules = [
    ClassificationRule(sessionClass: .infrastructure, marker: nil) { header in
      SessionReader.infrastructurePrefixes.contains { header.name?.hasPrefix($0) == true }
    },
    ClassificationRule(sessionClass: .child, marker: .parentSession) { $0.parentSession != nil },
    ClassificationRule(sessionClass: .child, marker: .agentName) {
      SessionReader.isAgentName($0.name)
    },
  ]

  private static let folderRules = [
    FolderRule(kind: "observer-memory", marker: "-.memory-"),
    FolderRule(kind: "task-worktree", marker: "-task-worktrees-"),
    FolderRule(kind: "herdr-worktree", marker: "-.herdr-worktrees-"),
    FolderRule(kind: "temporary", marker: "--private-var-folders-"),
    FolderRule(kind: "temporary", marker: "--var-folders-"),
    FolderRule(kind: "temporary", marker: "--private-tmp"),
    FolderRule(kind: "temporary", marker: "--tmp-"),
  ]

  private static let fractionalTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let wholeTimestamp = Date.ISO8601FormatStyle()

  let sessions: URL
  let snippets: [String]
  let templates: [String]
  let environment: [String: String]
  let snippetFolder: URL?
  let promptFolder: URL?

  public init(
    sessions: URL, snippets: URL?, prompts: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw MemoryError("missing sessions directory") }
    self.sessions = sessions
    self.environment = environment
    self.snippetFolder = snippets
    self.promptFolder = prompts
    self.snippets =
      try snippets.map { folder in
        let bodies = Self.markdownFiles(in: folder).compactMap(Self.snippetBody)
        guard !bodies.isEmpty else { throw MemoryError("no snippet bodies in --snippets") }
        return bodies
      } ?? []
    self.templates =
      try prompts.map { folder in
        let bodies = Self.markdownFiles(in: folder).compactMap(Self.templateBody)
        guard !bodies.isEmpty else { throw MemoryError("no prompt templates in --prompts") }
        return bodies
      } ?? []
  }

  var isSnippetsLoaded: Bool { !snippets.isEmpty }
  var isPromptsLoaded: Bool { !templates.isEmpty }

  private static func markdownFiles(in folder: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.sorted().filter { $0.lowercased().hasSuffix(".md") }.compactMap { name in
      try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }
  }

  public func files(modifiedAfter: Date) throws -> [URL] {
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    var found: [URL] = []
    for folderName in try manager.contentsOfDirectory(atPath: sessions.path) {
      let folder = sessions.appendingPathComponent(folderName)
      guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
        let names = try? manager.contentsOfDirectory(atPath: folder.path)
      else { continue }
      for name in names where name.hasSuffix(".jsonl") {
        let file = folder.appendingPathComponent(name)
        guard let values = try? file.resourceValues(forKeys: keys) else { continue }
        if values.isRegularFile == true, let date = values.contentModificationDate,
          date > modifiedAfter
        {
          found.append(file)
        }
      }
    }
    return found.sorted { $0.path < $1.path }
  }

  public func read(_ file: URL, window: EntryWindow, keys: inout ProjectKeys) throws
    -> SessionDigest
  {
    let path = file.path
    let lines = try Self.firstLines(of: file, count: 20)
    guard let header = Self.header(lines) else {
      return .skipped(path: path, sessionClass: .unreadable, name: nil)
    }
    let (sessionClass, marker) = Self.classify(header)
    guard sessionClass == .primary || sessionClass == .child else {
      return .skipped(path: path, sessionClass: sessionClass, name: header.name)
    }
    let data = try Data(contentsOf: file)
    let project = keys.key(cwd: header.cwd, parentPath: header.parentSession)
    var parse = SessionParse(
      header: header, window: window, isPrimary: sessionClass == .primary, snippets: snippets,
      templates: templates,
      projectKey: project.key, projectAlias: project.alias)
    parse.counts.bytesRead = data.count
    parse.consume(data)
    return parse.digest(path: path, marker: marker ?? .parentSession)
  }

  public func scan(window: EntryWindow, sampleLimit: Int) throws -> (
    digests: [SessionDigest], census: Census
  ) {
    let started = Date()
    let files = try files(modifiedAfter: window.filesModifiedAfter)
    let starts =
      files.indices.filter { index in
        index == 0
          || files[index].deletingLastPathComponent()
            != files[index - 1].deletingLastPathComponent()
      } + [files.count]
    let units = zip(starts, starts.dropFirst()).map { $0..<$1 }
    let results = ScanResults(count: files.count)
    let workers = max(1, min(units.count, ProcessInfo.processInfo.activeProcessorCount))
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
      var keys = ProjectKeys(environment: environment)
      while let unit = results.nextUnit(of: units) {
        for index in unit {
          let digest =
            (try? read(files[index], window: window, keys: &keys))
            ?? .skipped(path: files[index].path, sessionClass: .unreadable, name: nil)
          results.store(digest, at: index)
        }
      }
      results.store(keys)
    }
    var digests = results.digests
    Self.link(&digests)
    let census = Self.census(
      digests, window: window, keys: results.keys, isSnippetsLoaded: isSnippetsLoaded,
      isPromptsLoaded: isPromptsLoaded, seconds: Date().timeIntervalSince(started),
      sampleLimit: sampleLimit)
    return (digests, census)
  }

  static func classify(_ header: SessionHeader) -> (SessionClass, ChildMarker?) {
    guard let rule = classificationRules.first(where: { $0.matches(header) }) else {
      return (.primary, nil)
    }
    return (rule.sessionClass, rule.marker)
  }

  static func isAgentName(_ name: String?) -> Bool {
    guard let name, let separator = name.unicodeScalars.firstIndex(of: "#") else { return false }
    let agent = name.unicodeScalars[..<separator]
    let suffix = name.unicodeScalars[name.unicodeScalars.index(after: separator)...]
    guard let first = agent.first, ("a"..."z").contains(first), suffix.count >= 6 else {
      return false
    }
    return agent.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
      && suffix.allSatisfy { ("a"..."f").contains($0) || ("0"..."9").contains($0) }
  }

  static func humanText(
    _ raw: String, snippets: [String], templates: [String] = [], isClipped: Bool = true
  ) -> HumanText {
    let skillPattern =
      #"\A<skill name="([^"]+)" location="([^"]+)">\n([\s\S]*?)\n</skill>(?:\n\n([\s\S]+))?\z"#
    guard let skill = groups(skillPattern, in: raw) else {
      return plainText(raw, snippets: snippets, templates: templates, isClipped: isClipped)
    }
    return commandArguments(skill[4], snippets: snippets, isClipped: isClipped)
  }

  private static func commandArguments(
    _ arguments: String?, snippets: [String], isClipped: Bool
  ) -> HumanText {
    guard let arguments else { return .skillOnly }
    switch plainText(arguments, snippets: snippets, templates: [], isClipped: isClipped) {
    case .human(let text, _): return .human(text, .typedSkillArguments)
    case .empty, .snippetOnly: return .skillOnly
    case let other: return other
    }
  }

  private static func plainText(
    _ raw: String, snippets: [String], templates: [String], isClipped: Bool
  )
    -> HumanText
  {
    var text = raw
    for envelope in injectedEnvelopes {
      text = envelope.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
    if text.contains("<file name=\"") || text.contains("</file>") { return .unknownMarkup }
    var isSnippetRemoved = false
    var isChanged = true
    while isChanged {
      isChanged = false
      for body in snippets {
        if text == body {
          text = ""
        } else if text.hasPrefix(body + "\n\n") {
          text = String(text.dropFirst(body.count + 2))
        } else if text.hasSuffix("\n\n" + body) {
          text = String(text.dropLast(body.count + 2))
        } else {
          continue
        }
        isChanged = true
        isSnippetRemoved = true
      }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return isSnippetRemoved ? .snippetOnly : .empty }
    for template in templates {
      if let captures = groups(templatePattern(template), in: text) {
        return commandArguments(
          templateArguments(captures.dropFirst(), template: template), snippets: snippets,
          isClipped: isClipped)
      }
    }
    if trimmed.count <= 12, acknowledgements.contains(trimmed.lowercased()) {
      return .acknowledgement
    }
    return .human(isClipped ? middleCut(trimmed, limit: promptLimit) : trimmed, .typed)
  }

  static func templatePattern(_ body: String) -> String {
    let placeholder =
      #"\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)"#
    guard let expression = try? NSRegularExpression(pattern: placeholder) else { return "(?!)" }
    var pattern = "\\A"
    var literalStart = body.startIndex
    for match in expression.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
      guard let range = Range(match.range, in: body) else { continue }
      pattern += NSRegularExpression.escapedPattern(
        for: String(body[literalStart..<range.lowerBound]))
      pattern += #"([\s\S]*?)"#
      literalStart = range.upperBound
    }
    return pattern + NSRegularExpression.escapedPattern(for: String(body[literalStart...])) + "\\z"
  }

  static func templateArguments(_ captures: ArraySlice<String?>, template: String) -> String? {
    let placeholder =
      #"\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)"#
    guard let expression = try? NSRegularExpression(pattern: placeholder) else { return nil }
    let matches = expression.matches(
      in: template, range: NSRange(template.startIndex..., in: template))
    var kept: [String] = []
    for (capture, match) in zip(captures, matches) {
      guard let value = capture?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
      else {
        continue
      }
      if let range = Range(match.range(at: 2), in: template),
        value == template[range].trimmingCharacters(in: .whitespacesAndNewlines)
      {
        continue
      }
      if !kept.contains(value) { kept.append(value) }
    }
    return kept.isEmpty ? nil : kept.joined(separator: " ")
  }

  static func answers(_ details: [String: Any]) -> [(
    evidence: HumanEvidence, text: String, question: String
  )] {
    guard details["status"] as? String == "answered",
      let answers = details["answers"] as? [[String: Any]]
    else { return [] }
    let labeled = answerParts(answers)
    let question = details["question"] as? String ?? ""
    let typed = labeled.filter { $0.type != "option" }.map(\.label)
    let picked = labeled.filter { $0.type == "option" }.map(\.label)
    return [(HumanEvidence.answered, typed), (.picked, picked)].compactMap { evidence, labels in
      labels.isEmpty ? nil : (evidence, labels.joined(separator: "; "), question)
    }
  }

  static func answerParts(_ answers: [[String: Any]]) -> [(type: String, label: String)] {
    answers.compactMap { answer in
      guard let type = answer["type"] as? String, ["text", "other", "option"].contains(type),
        let label = (answer["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !label.isEmpty
      else { return nil }
      return (type, label)
    }
  }

  func preparationFiles() throws -> [PreparationSessionFile] {
    let root = try PreparationDirectory(url: sessions)
    var files: [PreparationSessionFile] = []
    for folderName in try root.names() {
      let folderKind = try root.kind(folderName)
      guard folderKind != S_IFLNK else {
        throw MemoryError("unsafe session folder: \(folderName)")
      }
      guard folderKind == S_IFDIR else { continue }
      let folder = try PreparationDirectory(
        url: sessions.appendingPathComponent(folderName), parent: root)
      for name in try folder.names() where name.hasSuffix(".jsonl") {
        files.append(
          PreparationSessionFile(
            path: try SourceRelativePath(folderName + "/" + name), directory: folder, name: name))
      }
    }
    return files
  }

  static func link(_ digests: inout [SessionDigest]) {
    var requests: [String: [(digest: Int, exchange: Int)]] = [:]
    for (index, digest) in digests.enumerated() {
      let name = URL(fileURLWithPath: digest.path).lastPathComponent
      for (position, exchange) in digest.exchanges.enumerated() {
        requests[name + "\n" + exchange.prompt, default: []].append((index, position))
      }
    }
    for index in digests.indices {
      guard case .child(var child) = digests[index], let prompt = child.orchestration.first else {
        continue
      }
      let parentName = child.header.parentSession.map { URL(fileURLWithPath: $0).lastPathComponent }
      let key = parentName.map { $0 + "\n" + prompt.text }
      guard let key, let target = requests[key]?.first else {
        child.exchanges.insert(
          SubagentExchange(
            request: prompt.citation, agentId: nil, childSession: child.header.id,
            subagentType: child.header.name.flatMap { name in
              isAgentName(name) ? name.split(separator: "#").first.map(String.init) : nil
            },
            description: nil, prompt: prompt.text, report: child.finalText,
            projectKey: child.projectKey), at: 0)
        digests[index] = .child(child)
        continue
      }
      requests[key]?.removeFirst()
      var exchanges = digests[target.digest].exchanges
      let exchange = exchanges[target.exchange]
      var report = exchange.report
      if let finalText = child.finalText,
        report.map({ $0.text == finalText.text }) ?? true
      {
        report = finalText
      }
      exchanges[target.exchange] = SubagentExchange(
        request: exchange.request, agentId: exchange.agentId, childSession: child.header.id,
        subagentType: exchange.subagentType, description: exchange.description,
        prompt: exchange.prompt, report: report, projectKey: exchange.projectKey)
      digests[target.digest].exchanges = exchanges
    }
  }

  static func decodeRecord(_ line: Data) throws -> Any {
    do { return try JSONSerialization.jsonObject(with: line) } catch {
      return try JSONSerialization.jsonObject(with: repairSurrogates(line))
    }
  }

  static func repairSurrogates(_ line: Data) -> Data {
    let bytes = [UInt8](line)
    var repaired: [UInt8] = []
    repaired.reserveCapacity(bytes.count)
    let replacement = Array(#"\uFFFD"#.utf8)
    func unit(at index: Int) -> UInt16? {
      guard index + 6 <= bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
        return nil
      }
      return UInt16(String(decoding: bytes[(index + 2)..<(index + 6)], as: UTF8.self), radix: 16)
    }
    var index = 0
    while index < bytes.count {
      guard bytes[index] == 0x5C, index + 1 < bytes.count else {
        repaired.append(bytes[index])
        index += 1
        continue
      }
      guard let value = unit(at: index) else {
        repaired.append(contentsOf: bytes[index..<(index + 2)])
        index += 2
        continue
      }
      if (0xD800...0xDBFF).contains(value), let low = unit(at: index + 6),
        (0xDC00...0xDFFF).contains(low)
      {
        repaired.append(contentsOf: bytes[index..<(index + 12)])
        index += 12
      } else if (0xD800...0xDFFF).contains(value) {
        repaired.append(contentsOf: replacement)
        index += 6
      } else {
        repaired.append(contentsOf: bytes[index..<(index + 6)])
        index += 6
      }
    }
    return Data(repaired)
  }

  public static func middleCut(_ text: String, limit: Int) -> String {
    let count = text.count
    guard count > limit else { return text }
    let head = limit * 6 / 10
    let tail = limit - head
    return String(text.prefix(head)) + "\n[… \(count - limit) characters cut …]\n"
      + String(text.suffix(tail))
  }

  static func paths(tool: String, arguments: [String: Any], cwd: String) -> [String] {
    let candidates: [String]
    switch tool {
    case "read", "edit", "write", "grep", "find":
      candidates = [arguments["path"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
    case "bash":
      candidates = (arguments["command"] as? String).map(commandPaths) ?? []
    default:
      candidates = []
    }
    let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
    return candidates.map { $0.hasPrefix(base) ? String($0.dropFirst(base.count)) : $0 }
  }

  static func commandPaths(_ command: String) -> [String] {
    let quotes = CharacterSet(charactersIn: "'\"`;,()")
    return command.split(whereSeparator: \.isWhitespace)
      .map { $0.trimmingCharacters(in: quotes) }
      .filter { token in
        !token.contains("://")
          && (token.contains("/") || pathExtensions.contains { token.hasSuffix($0) })
      }
  }

  public static func date(_ text: String) -> Date? {
    (try? Date(text, strategy: fractionalTimestamp)) ?? (try? Date(text, strategy: wholeTimestamp))
  }

  static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func templateBody(_ raw: String) -> String? {
    let body = snippetBody(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? nil : body
  }

  static func snippetBody(_ raw: String) -> String? {
    guard
      let parts = groups(#"\A---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)\z"#, in: raw),
      let body = parts[2]?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty
    else { return nil }
    return body
  }

  static func groups(_ pattern: String, in text: String) -> [String?]? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<match.numberOfRanges).map { group in
      Range(match.range(at: group), in: text).map { String(text[$0]) }
    }
  }

  static func firstLines(of file: URL, count: Int) throws -> [Data] {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var buffer = Data()
    var lines: [Data] = []
    while lines.count < count, let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
      buffer.append(chunk)
      while lines.count < count, let newline = buffer.firstIndex(of: 0x0A) {
        lines.append(Data(buffer[buffer.startIndex..<newline]))
        buffer = Data(buffer[(newline + 1)...])
      }
    }
    return lines
  }

  static func header(_ lines: [Data]) -> SessionHeader? {
    guard let first = lines.first,
      let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
      object["type"] as? String == "session", let id = object["id"] as? String,
      let cwd = object["cwd"] as? String,
      let timestamp = (object["timestamp"] as? String).flatMap(date)
    else { return nil }
    let name = lines.dropFirst().lazy.compactMap { line -> String? in
      guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        entry["type"] as? String == "session_info"
      else { return nil }
      return entry["name"] as? String ?? ""
    }.first
    return SessionHeader(
      id: id, cwd: cwd, timestamp: timestamp, parentSession: object["parentSession"] as? String,
      name: name.flatMap { $0.isEmpty ? nil : $0 })
  }

  static func folderKind(_ path: String) -> String {
    let folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    return folderRules.first { folder.contains($0.marker) }?.kind ?? "other"
  }

  private static func census(
    _ digests: [SessionDigest], window: EntryWindow, keys: [ProjectKeys], isSnippetsLoaded: Bool,
    isPromptsLoaded: Bool, seconds: Double, sampleLimit: Int
  ) -> Census {
    var sessions = Dictionary(uniqueKeysWithValues: SessionClass.allCases.map { ($0, 0) })
    var infrastructure: [String: Int] = [:]
    var markers: [ChildMarker: Int] = [:]
    var folders: [SessionClass: [String: Int]] = [:]
    var counts = ReaderCounts()
    var agent: [AgentSource: Int] = [:]
    var exchanges = 0
    var pathTouches = 0
    var stuckSignals = 0
    var samples: [HumanEvidence: [String]] = [:]
    func tally(_ statements: [AgentStatement]) {
      for statement in statements { agent[statement.source, default: 0] += 1 }
    }
    for digest in digests {
      sessions[digest.sessionClass, default: 0] += 1
      folders[digest.sessionClass, default: [:]][folderKind(digest.path), default: 0] += 1
      exchanges += digest.exchanges.count
      tally(digest.exchanges.compactMap(\.report).filter { $0.source != .childFinalText })
      switch digest {
      case .primary(let primary):
        counts.add(primary.counts)
        tally(primary.agent)
        pathTouches += primary.paths.count
        stuckSignals += primary.stuck.count
        for utterance in primary.human
        where samples[utterance.evidence, default: []].count < sampleLimit {
          samples[utterance.evidence, default: []].append(utterance.text)
        }
      case .child(let child):
        markers[child.marker, default: 0] += 1
        counts.add(child.counts)
        tally(child.orchestration + child.agent + (child.finalText.map { [$0] } ?? []))
        pathTouches += child.paths.count
        stuckSignals += child.stuck.count
      case .skipped(_, let sessionClass, let name):
        if sessionClass == .infrastructure,
          let prefix = infrastructurePrefixes.first(where: { name?.hasPrefix($0) == true })
        {
          infrastructure[String(prefix.dropLast()), default: 0] += 1
        }
      }
    }
    return Census(
      window: window, files: digests.count, sessions: sessions, infrastructure: infrastructure,
      childMarkers: markers, folders: folders, counts: counts, agent: agent, exchanges: exchanges,
      pathTouches: pathTouches, stuckSignals: stuckSignals,
      projectsResolved: keys.reduce(0) { $0 + $1.resolved },
      projectsViaParent: keys.reduce(0) { $0 + $1.viaParent },
      projectsUnresolved: keys.reduce(0) { $0 + $1.unresolved }, isSnippetsLoaded: isSnippetsLoaded,
      isPromptsLoaded: isPromptsLoaded, seconds: seconds, samples: samples)
  }
}

private final class ScanResults: @unchecked Sendable {
  private let lock = NSLock()
  private var slots: [SessionDigest?]
  private var nextIndex = 0
  private var storedKeys: [ProjectKeys] = []

  init(count: Int) {
    slots = Array(repeating: nil, count: count)
  }

  var digests: [SessionDigest] {
    locked { slots.compactMap { $0 } }
  }

  var keys: [ProjectKeys] {
    locked { storedKeys }
  }

  func nextUnit(of units: [Range<Int>]) -> Range<Int>? {
    locked {
      guard nextIndex < units.count else { return nil }
      defer { nextIndex += 1 }
      return units[nextIndex]
    }
  }

  func store(_ digest: SessionDigest, at index: Int) {
    locked { slots[index] = digest }
  }

  func store(_ projectKeys: ProjectKeys) {
    locked { storedKeys.append(projectKeys) }
  }

  private func locked<Value>(_ body: () -> Value) -> Value {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private struct ChainLink {
  let parent: String?
  let text: String?
}

private struct PendingExchange {
  let request: Citation
  let toolCallId: String
  let subagentType: String?
  let description: String?
  let prompt: String
}

private struct Report {
  let citation: Citation
  let text: String
}

private enum Needle {
  static let toolResult = Array(#""role":"toolResult""#.utf8)
  static let contextEdit = Array(#""type":"context_edit""#.utf8)
  static let error = Array(#""isError":true"#.utf8)
  static let kept = [
    Array(#""toolName":"ask_user_question""#.utf8),
    Array(#""toolName":"get_subagent_result""#.utf8),
    Array(#""toolName":"Agent""#.utf8),
  ]
  static let id = Array(#""id":""#.utf8)
  static let parentId = Array(#""parentId":""#.utf8)
}

private struct SessionParse {
  let header: SessionHeader
  let window: EntryWindow
  let isPrimary: Bool
  let snippets: [String]
  let templates: [String]
  let projectKey: String?
  let projectAlias: String
  var counts = ReaderCounts()
  var chain: [String: ChainLink] = [:]
  var human: [HumanUtterance] = []
  var texts: [(citation: Citation, text: String)] = []
  var orchestration: [AgentStatement] = []
  var pending: [PendingExchange] = []
  var agentIds: [String: String] = [:]
  var records: [String: Report] = [:]
  var fetched: [(agentId: String?, report: Report)] = []
  var paths: [PathTouch] = []
  var seenPaths: Set<PathTouch> = []
  var errorRun: [Citation] = []
  var errorExcerpt = ""
  var commands: [String: [Citation]] = [:]
  var commandOrder: [String] = []
  var stuck: [StuckSignal] = []

  init(
    header: SessionHeader, window: EntryWindow, isPrimary: Bool, snippets: [String],
    templates: [String], projectKey: String?, projectAlias: String
  ) {
    self.header = header
    self.window = window
    self.isPrimary = isPrimary
    self.snippets = snippets
    self.templates = templates
    self.projectKey = projectKey
    self.projectAlias = projectAlias
  }

  mutating func consume(_ data: Data) {
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      guard let base = buffer.baseAddress else { return }
      var start = 0
      while start < buffer.count {
        guard let newline = memchr(base + start, 0x0A, buffer.count - start) else {
          counts.inFlightLines += 1
          return
        }
        let end = base.distance(to: UnsafeRawPointer(newline))
        if end > start { take(UnsafeRawBufferPointer(rebasing: buffer[start..<end])) }
        start = end + 1
      }
    }
    endErrorRun()
  }

  private func isFound(_ line: UnsafeRawBufferPointer, _ needle: [UInt8], within limit: Int) -> Bool
  {
    memmem(line.baseAddress, min(limit, line.count), needle, needle.count) != nil
  }

  private func field(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> String? {
    let prefix = UnsafeRawBufferPointer(rebasing: line.prefix(300))
    guard let base = prefix.baseAddress,
      let found = memmem(base, prefix.count, needle, needle.count)
    else { return nil }
    let start = base.distance(to: UnsafeRawPointer(found)) + needle.count
    guard let end = prefix[start...].firstIndex(of: 0x22) else { return nil }
    return String(decoding: prefix[start..<end], as: UTF8.self)
  }

  private mutating func take(_ line: UnsafeRawBufferPointer) {
    let isToolResult = isFound(line, Needle.toolResult, within: 300)
    let isPrefiltered =
      (isToolResult && !Needle.kept.contains { isFound(line, $0, within: 600) }
        && !isFound(line, Needle.error, within: line.count))
      || isFound(line, Needle.contextEdit, within: 300)
    if isPrefiltered {
      if let id = field(line, Needle.id) {
        chain[id] = ChainLink(parent: field(line, Needle.parentId), text: nil)
      }
      if isToolResult { endErrorRun() }
      return
    }
    let data = Data(line)
    guard let object = (try? SessionReader.decodeRecord(data)) as? [String: Any] else {
      counts.undecodableLines += 1
      return
    }
    apply(object)
  }

  private mutating func apply(_ object: [String: Any]) {
    let type = object["type"] as? String
    guard type != "session" else { return }
    let id = object["id"] as? String
    let parent = object["parentId"] as? String
    let timestamp = (object["timestamp"] as? String).flatMap(SessionReader.date)
    if timestamp == nil { counts.untimedEntries += 1 }
    let isNew = timestamp.map(window.isNew) ?? false
    let citation = Citation(session: header.id, entry: id ?? "")
    if let id { chain[id] = ChainLink(parent: parent, text: nil) }
    switch type {
    case "message":
      guard let message = object["message"] as? [String: Any] else { return }
      switch message["role"] as? String {
      case "user":
        if isNew, let timestamp { user(message, citation: citation, at: timestamp, parent: parent) }
      case "assistant":
        assistant(message, citation: citation, parent: parent, isNew: isNew)
      case "toolResult":
        toolResult(message, citation: citation, at: timestamp, parent: parent, isNew: isNew)
      default:
        break
      }
    case "custom":
      guard isNew, object["customType"] as? String == "subagents:record",
        let data = object["data"] as? [String: Any], let agentId = data["id"] as? String
      else { return }
      if let result = data["result"] as? String, !result.isEmpty {
        records[agentId] = Report(citation: citation, text: result)
      } else {
        records[agentId] = nil
      }
    case "custom_message":
      if isNew { counts.customMessages += 1 }
    default:
      break
    }
  }

  private static func texts(_ content: Any?) -> [String] {
    if let text = content as? String { return [text] }
    return (content as? [[String: Any]] ?? []).compactMap { block in
      block["type"] as? String == "text" ? block["text"] as? String : nil
    }
  }

  private func context(from parent: String?) -> String? {
    var next = parent
    var hops = 0
    while let id = next, let link = chain[id], hops < 10_000 {
      if let text = link.text { return text }
      next = link.parent
      hops += 1
    }
    return nil
  }

  private mutating func user(
    _ message: [String: Any], citation: Citation, at timestamp: Date, parent: String?
  ) {
    let raw = Self.texts(message["content"]).joined(separator: "\n")
    guard isPrimary else {
      let text = SessionReader.middleCut(raw, limit: SessionReader.promptLimit)
      orchestration.append(statement(.orchestration, citation, text))
      return
    }
    switch SessionReader.humanText(raw, snippets: snippets, templates: templates) {
    case .human(let text, let evidence):
      counts.human[evidence, default: 0] += 1
      human.append(
        HumanUtterance(
          citation: citation, timestamp: timestamp, evidence: evidence, text: text, question: nil,
          agentContext: context(from: parent), projectKey: projectKey))
    case .unknownMarkup: counts.unknownMarkup += 1
    case .skillOnly: counts.skillOnly += 1
    case .snippetOnly: counts.snippetOnly += 1
    case .acknowledgement: counts.acknowledgements += 1
    case .empty: break
    }
  }

  private mutating func assistant(
    _ message: [String: Any], citation: Citation, parent: String?, isNew: Bool
  ) {
    let blocks = message["content"] as? [[String: Any]] ?? []
    let blockTexts = Self.texts(blocks).filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if !citation.entry.isEmpty, let last = blockTexts.last {
      chain[citation.entry] = ChainLink(
        parent: parent, text: String(last.suffix(SessionReader.contextLimit)))
    }
    guard isNew else { return }
    texts += blockTexts.map { (citation: citation, text: $0) }
    for call in blocks where call["type"] as? String == "toolCall" {
      toolCall(call, citation: citation)
    }
    switch message["stopReason"] as? String {
    case "aborted":
      stuck.append(signal(.abortedTurn, [citation], blockTexts.last ?? ""))
    case "length":
      stuck.append(signal(.lengthStop, [citation], blockTexts.last ?? ""))
    default:
      break
    }
  }

  private mutating func toolCall(_ call: [String: Any], citation: Citation) {
    let name = call["name"] as? String ?? ""
    let arguments = call["arguments"] as? [String: Any] ?? [:]
    if name == "Agent", let prompt = arguments["prompt"] as? String,
      let callId = call["id"] as? String
    {
      pending.append(
        PendingExchange(
          request: citation, toolCallId: callId,
          subagentType: arguments["subagent_type"] as? String,
          description: arguments["description"] as? String,
          prompt: SessionReader.middleCut(prompt, limit: SessionReader.promptLimit)))
    }
    for path in SessionReader.paths(tool: name, arguments: arguments, cwd: header.cwd) {
      let touch = PathTouch(
        projectKey: projectKey, projectAlias: projectAlias, path: path, tool: name,
        session: header.id)
      if seenPaths.insert(touch).inserted { paths.append(touch) }
    }
    if name == "bash", let command = arguments["command"] as? String {
      if commands[command] == nil { commandOrder.append(command) }
      commands[command, default: []].append(citation)
    }
  }

  private mutating func toolResult(
    _ message: [String: Any], citation: Citation, at timestamp: Date?, parent: String?, isNew: Bool
  ) {
    let text = Self.texts(message["content"]).joined(separator: "\n")
    let details = message["details"] as? [String: Any]
    if isNew, message["isError"] as? Bool == true {
      if errorRun.isEmpty { errorExcerpt = text }
      errorRun.append(citation)
    } else {
      endErrorRun()
    }
    switch message["toolName"] as? String {
    case "Agent":
      if let callId = message["toolCallId"] as? String,
        let agentId = Self.agentId(text) ?? details?["agentId"] as? String
      {
        agentIds[callId] = agentId
      }
    case "ask_user_question":
      guard isNew, let details, let timestamp else { return }
      let answers = SessionReader.answers(details)
      guard !answers.isEmpty else { return }
      guard isPrimary else {
        counts.childAnswers += 1
        return
      }
      for answer in answers {
        counts.human[answer.evidence, default: 0] += 1
        human.append(
          HumanUtterance(
            citation: citation, timestamp: timestamp, evidence: answer.evidence,
            text: SessionReader.middleCut(answer.text, limit: SessionReader.promptLimit),
            question: answer.question, agentContext: context(from: parent), projectKey: projectKey))
      }
    case "get_subagent_result":
      guard isNew, !text.isEmpty else { return }
      let firstLine = text.prefix { $0 != "\n" }
      let agentId = firstLine.hasPrefix("Agent: ") ? String(firstLine.dropFirst(7)) : nil
      let body = text.range(of: "\n\n").map { String(text[$0.upperBound...]) } ?? text
      if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        fetched.append((agentId: agentId, report: Report(citation: citation, text: body)))
      }
    default:
      break
    }
  }

  private static func agentId(_ text: String) -> String? {
    text.split(separator: "\n").first { $0.hasPrefix("Agent ID: ") }.map {
      String($0.dropFirst(10)).trimmingCharacters(in: .whitespaces)
    }
  }

  private mutating func endErrorRun() {
    if errorRun.count >= 3 { stuck.append(signal(.repeatedToolError, errorRun, errorExcerpt)) }
    errorRun = []
  }

  private func statement(_ source: AgentSource, _ citation: Citation, _ text: String)
    -> AgentStatement
  {
    AgentStatement(citation: citation, source: source, text: text, projectKey: projectKey)
  }

  private func signal(_ kind: StuckKind, _ citations: [Citation], _ excerpt: String) -> StuckSignal
  {
    StuckSignal(
      kind: kind, citations: citations,
      excerpt: SessionReader.middleCut(excerpt, limit: SessionReader.excerptLimit),
      projectKey: projectKey)
  }

  private func reports() -> (exchanges: [SubagentExchange], unmatched: [AgentStatement]) {
    var seen: Set<String> = []
    func report(_ found: Report?) -> AgentStatement? {
      guard let found else { return nil }
      let text = SessionReader.middleCut(found.text, limit: SessionReader.promptLimit)
      guard seen.insert(SessionReader.sha256(text)).inserted else { return nil }
      return statement(.subagentReport, found.citation, text)
    }
    let exchanges = pending.map { request in
      let agentId = agentIds[request.toolCallId]
      let found = agentId.flatMap { id in
        records[id] ?? fetched.first { $0.agentId == id }?.report
      }
      return SubagentExchange(
        request: request.request, agentId: agentId, childSession: nil,
        subagentType: request.subagentType, description: request.description,
        prompt: request.prompt, report: report(found), projectKey: projectKey)
    }
    let leftovers =
      records.values.sorted {
        ($0.citation.session, $0.citation.entry) < ($1.citation.session, $1.citation.entry)
      } + fetched.map(\.report)
    return (exchanges, leftovers.compactMap(report))
  }

  func digest(path: String, marker: ChildMarker) -> SessionDigest {
    var stuck = self.stuck
    for command in commandOrder where commands[command, default: []].count >= 3 {
      stuck.append(signal(.repeatedCommand, commands[command, default: []], command))
    }
    let (exchanges, unmatched) = reports()
    if isPrimary {
      let agent = texts.filter { $0.text.count >= SessionReader.primaryTextMinimum }.map {
        statement(
          .primaryText, $0.citation,
          SessionReader.middleCut($0.text, limit: SessionReader.textLimit))
      }
      return .primary(
        PrimaryDigest(
          header: header, path: path, projectKey: projectKey, projectAlias: projectAlias,
          human: human, agent: agent + unmatched, exchanges: exchanges, paths: paths, stuck: stuck,
          counts: counts))
    }
    let finalText = texts.last.map {
      statement(
        .childFinalText, $0.citation,
        SessionReader.middleCut($0.text, limit: SessionReader.promptLimit))
    }
    let agent = texts.dropLast().filter { $0.text.count >= SessionReader.childTextMinimum }.map {
      statement(
        .childText, $0.citation, SessionReader.middleCut($0.text, limit: SessionReader.textLimit))
    }
    return .child(
      ChildDigest(
        header: header, path: path, marker: marker, projectKey: projectKey,
        projectAlias: projectAlias, orchestration: orchestration, agent: agent + unmatched,
        finalText: finalText, exchanges: exchanges, paths: paths, stuck: stuck, counts: counts))
  }
}
