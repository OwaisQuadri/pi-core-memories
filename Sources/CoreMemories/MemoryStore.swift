import CryptoKit
import Darwin
import Foundation

private struct ProposalMetadata: Codable, Equatable {
  let base: String
  let file: String
  let reason: String
  let contradictions: String
}

public struct ApprovedDecisionDocument: Sendable {
  public let path: String
  public let mode: String?
  public let blob: String?
  public let digest: SourceDigest?
  public let bytes: Data?
  public let diagnostics: [String]
}

public struct ApprovedDecisionLayoutEntry: Equatable, Sendable {
  public let path: String
  public let mode: String
  public let blob: String
}

public struct ApprovedDecisionSnapshot: Sendable {
  public let base: String
  public let layoutHash: SourceDigest
  public let layoutEntryCount: Int
  public let layoutByteCount: Int
  public let layoutEntries: [ApprovedDecisionLayoutEntry]
  public let documents: [ApprovedDecisionDocument]

  init(
    base: String, layoutEntries: [ApprovedDecisionLayoutEntry],
    documents: [ApprovedDecisionDocument], limits: DreamDecisionLimits
  ) throws {
    guard MemoryDocument.isMatch(#"\A([0-9a-f]{40}|[0-9a-f]{64})\z"#, base),
      layoutEntries.map(\.path) == layoutEntries.map(\.path).sorted(),
      Set(layoutEntries.map(\.path)).count == layoutEntries.count,
      layoutEntries.contains(where: { $0.path == "MEMORY.md" }),
      documents.first?.path == "MEMORY.md",
      documents.map(\.path) == documents.map(\.path).sorted(),
      Set(documents.map(\.path)).count == documents.count
    else { throw DreamDecisionError.context("snapshot identity or ordering") }
    try limits.check(layoutEntries.count, maximum: limits.maximumLayoutEntries)
    let projectKeys = Set(documents.compactMap { document -> String? in
      switch DreamMemoryScope(path: document.path) {
      case .project(let key), .deviceProject(_, let key): return key
      default: return nil
      }
    })
    try limits.check(projectKeys.count, maximum: limits.maximumProjectKeys)
    let (scopeLimit, isScopeOverflow) = limits.maximumProjectKeys.multipliedReportingOverflow(by: 2)
    let (documentLimit, isDocumentOverflow) = scopeLimit.addingReportingOverflow(2)
    if !isScopeOverflow && !isDocumentOverflow {
      try limits.check(documents.count, maximum: max(limits.maximumLayoutEntries, documentLimit))
    }
    var layout = Data()
    for entry in layoutEntries {
      guard MemoryDocument.isAllowedPath(entry.path),
        ["100644", "100755"].contains(entry.mode),
        entry.blob.utf8.count == base.utf8.count,
        MemoryDocument.isMatch(#"\A[0-9a-f]+\z"#, entry.blob)
      else { throw DreamDecisionError.context("snapshot layout") }
      let tuple = Data("\(entry.path)\0\(entry.mode)\0\(entry.blob)\0".utf8)
      try limits.check(tuple.count, maximum: limits.maximumLayoutBytes - layout.count)
      layout.append(tuple)
    }
    var total = 0
    for document in documents {
      guard MemoryDocument.isAllowedPath(document.path) else {
        throw DreamDecisionError.context("snapshot document path")
      }
      let entry = layoutEntries.first { $0.path == document.path }
      if let bytes = document.bytes {
        guard let entry, document.mode == entry.mode, document.blob == entry.blob,
          document.digest == SourceDigest(bytes: bytes),
          let text = String(data: bytes, encoding: .utf8), !text.contains("\0"),
          document.diagnostics == MemoryDocument.failures(in: bytes)
        else { throw DreamDecisionError.context("snapshot document bytes") }
        try limits.check(bytes.count, maximum: limits.maximumDocumentBytes)
        try limits.accumulate(bytes.count, total: &total, maximum: limits.maximumSnapshotBytes)
      } else {
        guard entry == nil, document.path != "MEMORY.md", document.mode == nil,
          document.blob == nil, document.digest == nil, document.diagnostics.isEmpty
        else { throw DreamDecisionError.context("snapshot absence") }
      }
    }
    self.base = base
    self.layoutHash = SourceDigest(bytes: layout)
    self.layoutEntryCount = layoutEntries.count
    self.layoutByteCount = layout.count
    self.layoutEntries = layoutEntries
    self.documents = documents
  }

  package func reviewEntries() -> [(path: String, entry: MemoryDocument.MemoryEntry)] {
    let rows = documents.flatMap { document in
      MemoryDocument.entries(in: document.bytes ?? Data()).map { (path: document.path, entry: $0) }
    }
    let counts = rows.compactMap { $0.entry.identity }.reduce(into: [UUID: Int]()) {
      $0[$1, default: 0] += 1
    }
    return rows.map { row in
      guard let identity = row.entry.identity, counts[identity, default: 0] > 1 else { return row }
      let entry = row.entry
      return (
        row.path,
        MemoryDocument.MemoryEntry(
          locator: entry.locator, bytes: entry.bytes, identity: identity,
          lastReview: entry.lastReview, lastRevision: entry.lastRevision,
          isMutable: false, limitation: "duplicate memory identity in approved snapshot")
      )
    }
  }
}

private struct TreeEntry {
  let mode: String
  let oid: String
  let path: String
}

/// Reads approved memory and creates proposals in a dedicated Git repository.
/// Initialization accepts a repository URL and the inherited command environment.
/// - Returns: A store with main-only reads and separate proposal refs.
/// - Throws: Repository, document, and Git errors through its throwing operations.
public struct MemoryStore: Sendable {
  private let git: Git

  var reviewGit: Git { git }

  /// Opens an existing dedicated memory repository without initializing it.
  /// - Parameter repo: The data repository's working directory.
  /// - Parameter environment: Inherited variables; Git routing variables are discarded.
  /// - Returns: A store for the exact directory supplied.
  /// - Throws: If the directory is not a Git working-tree root.
  public init(repo: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws
  {
    let root = repo.standardizedFileURL.resolvingSymlinksInPath()
    git = Git(repo: root, environment: environment)
    guard try git.commonDirectory() != nil else { throw MemoryError("missing memory repository") }
    let top = try git.text(["rev-parse", "--show-toplevel"])
    guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.path else {
      throw MemoryError("--repo must name the memory repository root")
    }
  }

  /// Creates an empty dedicated repository with an initial main commit.
  /// - Parameter repo: A new path or an existing empty directory that is not a symlink.
  /// - Parameter environment: Inherited variables; Git routing variables are discarded.
  /// - Returns: Nothing; creates main and a header-only MEMORY.md.
  /// - Throws: On an occupied, symlinked, nested, or inaccessible destination, or a Git failure.
  public static func initialize(
    repo: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    let destination = repo.standardizedFileURL
    if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    {
      throw MemoryError("refusing a symlink path")
    }
    let isExisting = FileManager.default.fileExists(atPath: destination.path)
    if isExisting {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
        isDirectory.boolValue,
        try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty
      else { throw MemoryError("refusing an existing nonempty directory or file") }
    }
    var ancestor = destination
    while !FileManager.default.fileExists(atPath: ancestor.path) {
      ancestor.deleteLastPathComponent()
    }
    guard try Git(repo: ancestor, environment: environment).commonDirectory() == nil else {
      throw MemoryError("refusing a path inside another Git repository")
    }
    if !isExisting {
      try FileManager.default.createDirectory(
        at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: destination.path)
    let git = Git(repo: destination, environment: environment)
    _ = try git.data(["init", "--initial-branch=main", "--template="])
    let memory = destination.appendingPathComponent("MEMORY.md")
    let descriptor = open(memory.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw MemoryError("cannot create private MEMORY.md") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    try handle.write(contentsOf: Data("# Memory\n".utf8))
    _ = try git.data(["add", "--", "MEMORY.md"])
    _ = try git.data(
      ["commit", "-m", "Initialize empty approved memory"], additions: Git.proposalIdentity)
  }

  /// Identifies a project by its canonical Git common-directory path.
  /// - Parameter cwd: An existing directory in the project or outside Git.
  /// - Parameter environment: Inherited variables; Git routing variables are discarded.
  /// - Returns: A full lowercase SHA-256 key, or nil outside a repository.
  /// - Throws: If directory access or Git discovery fails for another reason.
  public static func projectKey(
    cwd: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    projectBindings: [String: String] = [:]
  ) throws -> String? {
    try MemoryScopeConfiguration.validate(deviceKey: nil, projectBindings: projectBindings)
    guard let canonical = try projectBindingDirectory(cwd: cwd, environment: environment) else { return nil }
    if let bound = projectBindings[canonical] { return bound }
    return SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  public static func projectBindingDirectory(
    cwd: URL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> String? {
    guard let common = try Git(repo: cwd, environment: environment).commonDirectory() else { return nil }
    guard let path = realpath(common.path, nil) else { throw MemoryError("cannot resolve Git common directory") }
    defer { free(path) }
    return String(cString: path)
  }

  /// Resolves the approved main commit.
  /// - Returns: The full object identifier at refs/heads/main; accepts no inputs.
  /// - Throws: If main is absent or does not resolve to a commit.
  public func approvedCommit() throws -> String {
    try git.text(["rev-parse", "--verify", "refs/heads/main^{commit}"])
  }

  /// Renders global and matching project Markdown from one main snapshot.
  /// - Parameter cwd: The directory used to select a project; outside Git selects only global memory.
  /// - Returns: Committed Markdown, excluding dirty files and all other projects.
  /// - Throws: On a missing store/main/global file, invalid selected memory, or Git failure.
  public func render(cwd: URL, deviceKey: String? = nil, projectBindings: [String: String] = [:]) throws -> String {
    try MemoryScopeConfiguration.validate(deviceKey: deviceKey, projectBindings: projectBindings)
    let commit = try approvedCommit()
    let key = try Self.projectKey(cwd: cwd, environment: git.environment, projectBindings: projectBindings)
    var paths = ["MEMORY.md"] + (key.map { ["projects/\($0).md"] } ?? [])
    if let deviceKey {
      paths.append("devices/\(deviceKey)/MEMORY.md")
      if let key { paths.append("devices/\(deviceKey)/projects/\(key).md") }
    }
    let entries = try treeEntries(commit, paths: paths)
    guard entries.contains(where: { $0.path == "MEMORY.md" }) else {
      throw MemoryError("missing committed MEMORY.md")
    }
    var documents: [String] = []
    for path in paths {
      if let entry = entries.first(where: { $0.path == path }) {
        documents.append(String(decoding: try document(entry), as: UTF8.self))
      }
    }
    let separator = documents.first?.unicodeScalars.last == "\n" ? "\n" : "\n\n"
    return documents.joined(separator: separator)
  }

  public func decisionSnapshot(
    base: String, projectKeys: [String], limits: DreamDecisionLimits = try! DreamDecisionLimits(),
    deviceKey: String? = nil
  ) throws -> ApprovedDecisionSnapshot {
    try decisionSnapshot(
      base: base, projectKeys: projectKeys, limits: limits, entries: nil, objects: nil,
      selectedPaths: MemoryScopeConfiguration.paths(projectKeys: projectKeys, deviceKey: deviceKey))
  }

  private func decisionSnapshot(
    base: String, projectKeys: [String], limits: DreamDecisionLimits,
    entries suppliedEntries: [TreeEntry]?, objects: ReviewGitObjects?, selectedPaths: [String]? = nil
  ) throws -> ApprovedDecisionSnapshot {
    guard Self.isFullOID(base),
      try objects.map({ try $0.info(base).type == "commit" })
        ?? (git.text(["rev-parse", "--verify", "\(base)^{commit}"]) == base),
      Set(projectKeys).count == projectKeys.count,
      projectKeys.allSatisfy({ MemoryDocument.isMatch(#"\A[0-9a-f]{64}\z"#, $0) })
    else { throw DreamDecisionError.context("snapshot identity") }
    try limits.check(projectKeys.count, maximum: limits.maximumProjectKeys)
    let entries = try (suppliedEntries ?? treeEntries(base)).sorted { $0.path < $1.path }
    try limits.check(entries.count, maximum: limits.maximumLayoutEntries)
    guard entries.contains(where: { $0.path == "MEMORY.md" }),
      entries.allSatisfy({
        MemoryDocument.isAllowedPath($0.path) && ($0.mode == "100644" || $0.mode == "100755")
      }), Set(entries.map(\.path)).count == entries.count
    else { throw DreamDecisionError.context("snapshot layout") }
    var layout = Data()
    for entry in entries {
      let tuple = Data("\(entry.path)\0\(entry.mode)\0\(entry.oid)\0".utf8)
      try limits.check(tuple.count, maximum: limits.maximumLayoutBytes - layout.count)
      layout.append(tuple)
      guard
        try (objects?.info(entry.oid).type ?? git.text(["cat-file", "-t", entry.oid])) == "blob"
      else {
        throw DreamDecisionError.context("snapshot object")
      }
    }
    let paths = selectedPaths ?? (["MEMORY.md"] + projectKeys.sorted().map { "projects/\($0).md" })
    guard paths.allSatisfy(MemoryDocument.isAllowedPath), paths == paths.sorted(),
      Set(paths).count == paths.count else { throw DreamDecisionError.context("selected memory paths") }
    var total = 0
    let documents = try paths.map { path in
      guard let entry = entries.first(where: { $0.path == path }) else {
        return ApprovedDecisionDocument(
          path: path, mode: nil, blob: nil, digest: nil, bytes: nil, diagnostics: [])
      }
      guard
        let size = try objects?.info(entry.oid).size
          ?? Int(git.text(["cat-file", "-s", entry.oid]))
      else {
        throw DreamDecisionError.context("snapshot object size")
      }
      try limits.check(size, maximum: limits.maximumDocumentBytes)
      try limits.accumulate(size, total: &total, maximum: limits.maximumSnapshotBytes)
      let bytes =
        try objects?.contents(entry.oid, type: "blob", maximumBytes: size)
        ?? git.data(["cat-file", "blob", entry.oid])
      guard bytes.count == size, let text = String(data: bytes, encoding: .utf8),
        !text.contains("\0")
      else { throw DreamDecisionError.context("snapshot encoding") }
      return ApprovedDecisionDocument(
        path: path, mode: entry.mode, blob: entry.oid, digest: SourceDigest(bytes: bytes),
        bytes: bytes, diagnostics: MemoryDocument.failures(in: bytes))
    }
    return try ApprovedDecisionSnapshot(
      base: base,
      layoutEntries: entries.map {
        ApprovedDecisionLayoutEntry(path: $0.path, mode: $0.mode, blob: $0.oid)
      }, documents: documents, limits: limits)
  }

  package func reviewSnapshot(
    base: String, limits: DreamDecisionLimits = try! DreamDecisionLimits()
  ) throws -> ApprovedDecisionSnapshot {
    try reviewSnapshot(base: base, limits: limits, objects: nil)
  }

  func reviewSnapshot(
    base: String, limits: DreamDecisionLimits = try! DreamDecisionLimits(),
    objects: ReviewGitObjects?
  ) throws -> ApprovedDecisionSnapshot {
    guard Self.isFullOID(base) else { throw DreamDecisionError.context("review snapshot base") }
    let entries = try treeEntries(base)
    let paths = entries.map(\.path)
    guard paths.allSatisfy(MemoryDocument.isAllowedPath) else {
      throw DreamDecisionError.context("review snapshot layout")
    }
    return try decisionSnapshot(
      base: base,
      projectKeys: [], limits: limits, entries: entries, objects: objects, selectedPaths: paths.sorted())
  }

  package func verifySavedProposal(
    plan: SingleFileProposalPlan, receipt: DreamProposalReceipt
  ) throws {
    guard Self.isFullOID(receipt.commit), receipt.base == plan.base, receipt.path == plan.path,
      receipt.ref == "refs/heads/proposals/\(receipt.commit)",
      try git.run(["symbolic-ref", "--quiet", receipt.ref]).status == 1,
      try git.text(["rev-parse", "--verify", receipt.ref]) == receipt.commit
    else { throw DreamRunError.corruption }
    let raw = try git.data(["cat-file", "commit", receipt.commit])
    guard let text = String(data: raw, encoding: .utf8),
      let separator = text.range(of: "\n\nCore memory proposal\n\n")
    else { throw DreamRunError.corruption }
    let parents = text[..<separator.lowerBound].split(separator: "\n")
      .filter { $0.hasPrefix("parent ") }.map { String($0.dropFirst(7)) }
    let metadata = try JSONDecoder().decode(
      ProposalMetadata.self, from: Data(text[separator.upperBound...].utf8))
    let entries = try treeEntries(receipt.commit, paths: [plan.path])
    guard parents == [plan.base],
      metadata
        == ProposalMetadata(
          base: plan.base, file: plan.path, reason: plan.reason, contradictions: plan.contradictions
        ),
      try changedPaths(from: plan.base, to: receipt.commit) == [plan.path],
      entries.count == 1, entries[0].mode == "100644", entries[0].path == plan.path,
      try git.data(["cat-file", "blob", entries[0].oid]) == plan.replacement
    else { throw DreamRunError.corruption }
  }

  /// Checks all approved files in one main snapshot.
  /// - Returns: FAIL lines for invalid paths, file types, or documents; accepts no inputs.
  /// - Throws: On a missing main commit or a Git read failure.
  public func check() throws -> [String] {
    let entries = try treeEntries(approvedCommit())
    var failures: [String] = []
    if !entries.contains(where: { $0.path == "MEMORY.md" }) {
      failures.append("FAIL MEMORY.md: missing committed file")
    }
    for entry in entries {
      let path = Self.safeReviewDisplay(entry.path)
        .replacingOccurrences(of: "\n", with: "\\u{A}")
        .replacingOccurrences(of: "\t", with: "\\u{9}")
      if !MemoryDocument.isAllowedPath(entry.path) {
        failures.append("FAIL \(path): path is not an allowed memory file")
      } else if entry.mode != "100644" && entry.mode != "100755" {
        failures.append("FAIL \(path): memory must be a regular file")
      } else {
        let data = try git.data(["cat-file", "blob", entry.oid])
        failures += MemoryDocument.failures(in: data).map { "FAIL \(path): \($0)" }
      }
    }
    return failures.map(Self.safeReviewDisplay)
  }

  /// Creates or reuses a deterministic single-file proposal without changing main or human files.
  /// - Parameter base: The full commit identifier currently approved on main.
  /// - Parameter path: MEMORY.md or a lowercase SHA-256 project file path.
  /// - Parameter replacement: Exact UTF-8 replacement Markdown.
  /// - Parameter reason: A nonempty explanation stored with the proposal.
  /// - Parameter contradictions: Known contradictions, stored verbatim; empty means none supplied.
  /// - Returns: The proposal ref, commit identifier, and exact base.
  /// - Throws: On invalid input, no change, stale main, publication conflict, or Git failure.
  public func propose(
    base: String, path: String, replacement: Data, reason: String, contradictions: String = ""
  ) throws -> (ref: String, commit: String, base: String) {
    try validateProposal(base: base, path: path, replacement: replacement, reason: reason)
    guard try approvedCommit() == base else {
      throw MemoryError("stale base: main no longer matches")
    }
    let commit = try proposalCommit(
      base: base, path: path, replacement: replacement, reason: reason,
      contradictions: contradictions)
    let ref = "refs/heads/proposals/\(commit)"
    let refs = ["refs/heads/main", ref]
    let result = try git.directRefTransaction(
      "verify refs/heads/main \(base)\ncreate \(ref) \(commit)\n", refs: refs, isolatedHead: base)
    if result.status != 0 {
      let verification = try git.directRefTransaction(
        "verify refs/heads/main \(base)\nverify \(ref) \(commit)\n", refs: refs, isolatedHead: base)
      guard verification.status == 0 else {
        throw MemoryError(verification.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    return (ref, commit, base)
  }

  public func recoverProposal(
    base: String, path: String, replacement: Data, reason: String, contradictions: String = ""
  ) throws -> (ref: String, commit: String, base: String)? {
    try validateProposal(base: base, path: path, replacement: replacement, reason: reason)
    let commit = try proposalCommit(
      base: base, path: path, replacement: replacement, reason: reason,
      contradictions: contradictions)
    let ref = "refs/heads/proposals/\(commit)"
    let symbolic = try git.run(["symbolic-ref", "--quiet", ref])
    guard symbolic.status == 1 else { throw MemoryError("ref must be direct: \(ref)") }
    let verification = try git.directRefTransaction(
      "verify \(ref) \(commit)\n", refs: [ref], isolatedHead: base)
    if verification.status != 0 {
      let absent = try git.directRefTransaction(
        "verify \(ref) \(String(repeating: "0", count: commit.count))\n", refs: [ref],
        isolatedHead: base)
      guard absent.status == 0 else {
        throw MemoryError(verification.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return nil
    }
    let raw = try git.text(["cat-file", "commit", commit])
    guard let separator = raw.range(of: "\n\nCore memory proposal\n\n") else {
      throw MemoryError("invalid proposal commit")
    }
    let parents = raw[..<separator.lowerBound].split(separator: "\n")
      .filter { $0.hasPrefix("parent ") }.map { String($0.dropFirst(7)) }
    let metadata = try JSONDecoder().decode(
      ProposalMetadata.self, from: Data(raw[separator.upperBound...].utf8))
    let entries = try treeEntries(commit, paths: [path])
    guard parents == [base],
      metadata
        == ProposalMetadata(
          base: base, file: path, reason: reason, contradictions: contradictions),
      try changedPaths(from: base, to: commit) == [path],
      entries.count == 1, entries[0].path == path, entries[0].mode == "100644",
      try git.data(["cat-file", "blob", entries[0].oid]) == replacement
    else { throw MemoryError("published proposal does not match the saved plan") }
    return (ref, commit, base)
  }

  private func validateProposal(base: String, path: String, replacement: Data, reason: String)
    throws
  {
    guard Self.isFullOID(base) else {
      throw MemoryError("base must be a full lowercase commit identifier")
    }
    guard MemoryDocument.isAllowedPath(path) else {
      throw MemoryError("path is not an allowed memory file")
    }
    let failures = MemoryDocument.failures(in: replacement)
    guard failures.isEmpty else { throw MemoryError(failures.joined(separator: "; ")) }
    guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MemoryError("reason must be nonempty")
    }
  }

  private func proposalCommit(
    base: String, path: String, replacement: Data, reason: String, contradictions: String
  ) throws -> String {
    let metadata = ProposalMetadata(
      base: base, file: path, reason: reason, contradictions: contradictions)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var message = Data("Core memory proposal\n\n".utf8)
    message.append(try encoder.encode(metadata))
    message.append(Data("\n".utf8))
    return try reviewCommit(base: base, path: path, replacement: replacement, message: message)
  }

  func publishCheckedMemoryCommit(
    commit: String, base: String, auditRef: String, checkout: ReviewCheckoutWitness
  ) throws {
    guard checkout.head == Data((checkout.commit + "\n").utf8), checkout.main == base else {
      throw MemoryError("publication requires the confirmed detached checkout")
    }
    let result = try git.directRefTransaction(
      "update refs/heads/main \(commit) \(base)\ncreate \(auditRef) \(commit)\n",
      refs: ["refs/heads/main", auditRef], isolatedHead: checkout.commit)
    guard result.status == 0 else {
      throw MemoryError("entry publication failed: \(result.errorText)")
    }
  }

  func reviewCommit(base: String, path: String, replacement: Data, message: Data) throws -> String {
    try reviewCommit(base: base, replacements: [path: replacement], message: message)
  }

  func reviewCommit(base: String, replacements: [String: Data], message: Data) throws -> String {
    guard Self.isFullOID(base), !replacements.isEmpty,
      replacements.allSatisfy({
        MemoryDocument.isAllowedPath($0.key) && MemoryDocument.failures(in: $0.value).isEmpty
      })
    else { throw MemoryError("invalid memory review commit") }
    let entries = try treeEntries(base)
    guard entries.contains(where: { $0.path == "MEMORY.md" }),
      entries.allSatisfy({
        MemoryDocument.isAllowedPath($0.path) && ($0.mode == "100644" || $0.mode == "100755")
      })
    else {
      throw MemoryError("base is not a dedicated memory store: invalid memory file layout")
    }
    var updatedEntries = entries.filter { replacements[$0.path] == nil }
    for path in replacements.keys.sorted() {
      let blob = try git.text(
        ["hash-object", "-w", "--stdin", "--no-filters"], input: replacements[path]!)
      updatedEntries.append(TreeEntry(mode: "100644", oid: blob, path: path))
    }
    func makeTree(_ entries: [TreeEntry], prefix: String) throws -> String {
      var records = ""
      var children: [String: [TreeEntry]] = [:]
      for entry in entries {
        let relative = String(entry.path.dropFirst(prefix.count))
        if let slash = relative.firstIndex(of: "/") {
          children[String(relative[..<slash]), default: []].append(entry)
        } else {
          records += "\(entry.mode) blob \(entry.oid)\t\(relative)\0"
        }
      }
      for name in children.keys.sorted() {
        let tree = try makeTree(children[name]!, prefix: prefix + name + "/")
        records += "040000 tree \(tree)\t\(name)\0"
      }
      return try git.text(["mktree", "-z"], input: Data(records.utf8))
    }
    let tree = try makeTree(updatedEntries, prefix: "")
    guard try changedPaths(from: base, to: tree) == replacements.keys.sorted() else {
      throw MemoryError("publication must change exactly its target files")
    }
    return try git.text(
      ["commit-tree", tree, "-p", base], input: message, additions: Git.proposalIdentity)
  }

  /// Shows proposal metadata and its parent-to-commit diff with terminal controls escaped.
  /// - Parameter commit: A full proposal commit identifier, not a revision expression.
  /// - Returns: Base, reason, contradictions, diff, and human-only fast-forward instructions.
  /// - Throws: On a non-proposal, mismatched parent or file, or Git failure.
  public func review(commit: String) throws -> String {
    guard Self.isFullOID(commit) else {
      throw MemoryError("proposal must be a full lowercase commit identifier")
    }
    let raw = try git.text(["cat-file", "commit", commit])
    guard let separator = raw.range(of: "\n\n") else {
      throw MemoryError("invalid proposal commit")
    }
    let header = raw[..<separator.lowerBound]
    let body = String(raw[separator.upperBound...])
    let prefix = "Core memory proposal\n\n"
    guard body.hasPrefix(prefix) else { throw MemoryError("not a core memory proposal") }
    let metadata = try JSONDecoder().decode(
      ProposalMetadata.self, from: Data(body.dropFirst(prefix.count).utf8))
    let parents = header.split(separator: "\n").filter { $0.hasPrefix("parent ") }
      .map { String($0.dropFirst(7)) }
    guard parents == [metadata.base], Self.isFullOID(metadata.base),
      MemoryDocument.isAllowedPath(metadata.file),
      try changedPaths(from: metadata.base, to: commit) == [metadata.file]
    else { throw MemoryError("proposal parent or changed file does not match its metadata") }
    let entries = try treeEntries(commit, paths: [metadata.file])
    guard entries.count == 1 else { throw MemoryError("proposal file is missing") }
    _ = try document(entries[0])
    let diff = String(
      decoding: try git.data([
        "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--binary",
        metadata.base, commit, "--",
      ]), as: UTF8.self)
    return Self.safeReviewDisplay(
      """
      Proposal: \(commit)
      Parent/Base: \(metadata.base)
      File: \(metadata.file)
      Reason:
      \(metadata.reason)
      Contradictions:
      \(metadata.contradictions)

      \(diff)
      HUMAN approval only: in the data repository, inspect this diff and confirm main still
      equals \(metadata.base) and the index/working tree are clean. Then run:
      git switch main
      git merge --ff-only \(commit)
      If main is stale or the data repository is dirty, reconcile it by hand.
      Never reset or force. This command does not approve or merge memory.

      """)
  }

  /// Escapes terminal controls for human review and diagnostics.
  /// - Parameter text: Display text that can contain untrusted Unicode scalars.
  /// - Returns: Text with unsafe controls escaped and printable Unicode unchanged.
  /// - Throws: Nothing.
  public static func safeReviewDisplay(_ text: String) -> String {
    var display = ""
    display.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0...8, 11...31, 127...159, 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x206F:
        display += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
      default:
        display.unicodeScalars.append(scalar)
      }
    }
    return display
  }

  static func isFullOID(_ text: String) -> Bool {
    MemoryDocument.isMatch(#"\A([0-9a-f]{40}|[0-9a-f]{64})\z"#, text)
  }

  private func changedPaths(from base: String, to target: String) throws -> [String] {
    let bytes = try git.committedChangedPathBytes(from: base, to: target)
    return String(decoding: bytes, as: UTF8.self).split(separator: "\0").map(String.init)
  }

  private func treeEntries(_ commit: String, paths: [String] = []) throws -> [TreeEntry] {
    let bytes = try git.data(["ls-tree", "-r", "-z", "--full-tree", commit, "--"] + paths)
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw MemoryError("invalid UTF-8 tree paths")
    }
    return try text.split(separator: "\0").map { record in
      let parts = record.split(separator: "\t", maxSplits: 1)
      guard parts.count == 2 else { throw MemoryError("invalid tree entry") }
      let fields = parts[0].split(separator: " ")
      guard fields.count == 3 else { throw MemoryError("invalid tree entry") }
      return TreeEntry(mode: String(fields[0]), oid: String(fields[2]), path: String(parts[1]))
    }
  }

  private func document(_ entry: TreeEntry) throws -> Data {
    guard entry.mode == "100644" || entry.mode == "100755" else {
      throw MemoryError("\(entry.path): memory must be a regular file")
    }
    let data = try git.data(["cat-file", "blob", entry.oid])
    let failures = MemoryDocument.readableFailures(in: data)
    guard failures.isEmpty else {
      throw MemoryError("\(entry.path): \(failures.joined(separator: "; "))")
    }
    return data
  }
}
