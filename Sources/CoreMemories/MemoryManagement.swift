import Darwin
import Foundation

package struct MemoryManagementRequest: Codable, Sendable {
  package enum Operation: String, Codable, Sendable { case list, get, add, update, delete }
  package let operation: Operation
  package var base: String?
  package var path: String?
  package var locator: MemoryDocument.EntryLocator?
  package var expected: String?
  package var replacement: String?
  package var reason: String?

  package init(
    operation: Operation, base: String? = nil, path: String? = nil,
    locator: MemoryDocument.EntryLocator? = nil, expected: String? = nil,
    replacement: String? = nil, reason: String? = nil
  ) {
    self.operation = operation
    self.base = base
    self.path = path
    self.locator = locator
    self.expected = expected
    self.replacement = replacement
    self.reason = reason
  }

  package static func decode(_ bytes: Data) throws -> Self {
    guard bytes.count <= 1_048_576,
      let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let operation = object["operation"] as? String
    else { throw MemoryError("invalid bounded management request") }
    let fields: Set<String>
    switch operation {
    case "list": fields = ["operation"]
    case "get": fields = ["operation", "base", "path", "locator", "expected"]
    case "add": fields = ["operation", "base", "path", "replacement", "reason"]
    case "update":
      fields = ["operation", "base", "path", "locator", "expected", "replacement", "reason"]
    case "delete": fields = ["operation", "base", "path", "locator", "expected", "reason"]
    default: throw MemoryError("unknown management operation")
    }
    guard Set(object.keys) == fields,
      object.values.allSatisfy({ !($0 is NSNull) })
    else { throw MemoryError("unexpected management request fields") }
    if let locator = object["locator"] as? [String: Any] {
      guard Set(locator.keys) == ["start", "end"] else {
        throw MemoryError("unexpected entry locator fields")
      }
    }
    return try JSONDecoder().decode(Self.self, from: bytes)
  }
}

package struct ManagedMemoryEntry: Codable, Sendable {
  package let path: String
  package let locator: MemoryDocument.EntryLocator
  package let expected: String
  package let identity: UUID?
  package let reviewed: String?
  package let revised: String?
  package let isMutable: Bool
  package let limitation: String?
}

package struct MemoryManagementResult: Codable, Sendable {
  package let base: String
  package let entries: [ManagedMemoryEntry]
  package let commit: String?
  package let auditRef: String?
  package let message: String
}

private struct MemoryManagementAudit: Codable {
  let schemaVersion: Int
  let origin: String
  let operation: MemoryManagementRequest.Operation
  let base: String
  let path: String
  let identity: UUID?
  let locator: MemoryDocument.EntryLocator?
  let before: String
  let after: String
  let reason: String
  let revised: String
}

struct PreparedManagementChange {
  let path: String
  let range: Range<Int>
  let insertion: Data
  let document: Data
  let audit: Data
}

package final class MemoryManagement {
  private let store: MemoryStore
  private let git: Git
  var afterCheckoutLocks: (() throws -> Void)?

  package init(repository: URL, environment: [String: String] = ProcessInfo.processInfo.environment)
    throws
  {
    store = try MemoryStore(repo: repository, environment: environment)
    git = store.reviewGit
  }

  package func execute(_ request: MemoryManagementRequest, date: Date = Date()) throws
    -> MemoryManagementResult
  {
    let base = try store.approvedCommit()
    guard request.operation == .list || request.base == base else {
      throw MemoryError(
        "approved base changed; list entries again before making the requested change")
    }
    let snapshot = try store.reviewSnapshot(base: base)
    let rows = snapshot.reviewEntries()
    let all = rows.map { row in
      ManagedMemoryEntry(
        path: row.path, locator: row.entry.locator,
        expected: String(decoding: row.entry.bytes, as: UTF8.self), identity: row.entry.identity,
        reviewed: row.entry.lastReview?.rawValue, revised: row.entry.lastRevision?.rawValue,
        isMutable: row.entry.isMutable, limitation: row.entry.limitation)
    }
    if request.operation == .list {
      return MemoryManagementResult(
        base: base, entries: all, commit: nil, auditRef: nil,
        message:
          "Current committed approved entries. Stored sources are references, not verified evidence."
      )
    }
    if request.operation == .get {
      guard let expected = request.expected,
        let row = all.first(where: {
          $0.path == request.path && $0.locator == request.locator
            && Data($0.expected.utf8) == Data(expected.utf8)
        })
      else { throw MemoryError("entry locator or expected bytes changed; list entries again") }
      return MemoryManagementResult(
        base: base, entries: [row], commit: nil, auditRef: nil,
        message: "Exact committed approved entry.")
    }
    let change = try prepare(request, snapshot: snapshot, date: date, newIdentity: UUID())
    return try publish(
      base: base, path: change.path, replacement: change.document, auditBytes: change.audit)
  }

  func prepare(
    _ request: MemoryManagementRequest, snapshot: ApprovedDecisionSnapshot,
    date: Date, newIdentity: UUID
  ) throws -> PreparedManagementChange {
    let base = snapshot.base
    let rows = snapshot.reviewEntries()
    guard let path = request.path, MemoryDocument.isAllowedPath(path) else {
      throw MemoryError("invalid memory path")
    }
    let entry: MemoryDocument.MemoryEntry?
    if request.operation == .add {
      guard request.locator == nil, request.expected == nil else {
        throw MemoryError("add cannot target an existing entry")
      }
      entry = nil
    } else {
      guard let locator = request.locator, let expected = request.expected,
        let found = rows.first(where: { $0.path == path && $0.entry.locator == locator }),
        found.entry.bytes == Data(expected.utf8)
      else { throw MemoryError("entry locator or expected bytes changed; list entries again") }
      entry = found.entry
    }
    guard entry == nil || entry?.isMutable == true,
      let reason = request.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      reason.utf8.count <= 16_384, !reason.contains("\0"), date.timeIntervalSince1970.isFinite
    else { throw MemoryError("entry is not mutable or change reason is invalid") }
    let identities = rows.compactMap { $0.entry.identity }
    guard Set(identities).count == identities.count else {
      throw MemoryError("duplicate memory identity in approved store")
    }
    let formatter = ISO8601DateFormatter()
    let instant = try MemoryDocument.ReviewInstant(formatter.string(from: date))
    let identity = entry?.identity ?? (request.operation == .delete ? nil : newIdentity)
    let after: Data
    if request.operation == .delete {
      guard request.replacement == nil else { throw MemoryError("delete cannot replace an entry") }
      after = Data()
    } else {
      guard let replacement = request.replacement, replacement.utf8.count <= 262_144,
        !replacement.contains("\0")
      else { throw MemoryError("missing or oversized entry replacement") }
      let bytes = Data(replacement.utf8)
      let sources = MemoryDocument.sourceAnnotations(in: bytes)
      guard
        MemoryDocument.sourceAnnotations(in: entry?.bytes ?? Data()).allSatisfy(sources.contains)
      else {
        throw MemoryError(
          "update must retain existing source annotations; add new references as needed")
      }
      let revised = try MemoryDocument.revisedBytes(
        bytes, previous: entry, identity: identity!, instant: instant)
      let terminator = entry?.bytes.suffix(2) == Data([13, 10]) ? Data([13, 10]) : Data([10])
      after = entry?.bytes.last == 10 && revised.last != 10 ? revised + terminator : revised
    }
    let document = snapshot.documents.first { $0.path == path }?.bytes ?? Data("# Memory\n".utf8)
    var replacement = document
    let range = entry.map { $0.locator.start..<$0.locator.end } ?? document.count..<document.count
    let insertion =
      request.operation == .add
      ? Data(
        (document.isEmpty || document.suffix(2) == Data([10, 10])
          ? "" : document.last == 10 ? "\n" : "\n\n").utf8) + after
      : after
    replacement.replaceSubrange(range, with: insertion)
    guard replacement.count <= 1_048_576, replacement != document,
      MemoryDocument.failures(in: replacement).isEmpty
    else { throw MemoryError("invalid or unchanged final memory document") }
    if let identity, request.operation != .delete {
      let targets = MemoryDocument.entries(in: replacement).filter { $0.identity == identity }
      guard targets.count == 1, targets[0].isMutable, targets[0].bytes == after else {
        throw MemoryError("replacement must remain one complete native entry")
      }
    }
    let audit = MemoryManagementAudit(
      schemaVersion: 1, origin: "explicit-user-request-agent-rule", operation: request.operation,
      base: base, path: path, identity: identity, locator: entry?.locator,
      before: String(decoding: entry?.bytes ?? Data(), as: UTF8.self),
      after: String(decoding: after, as: UTF8.self), reason: reason, revised: instant.rawValue)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let auditBytes = try encoder.encode(audit)
    return PreparedManagementChange(
      path: path, range: range, insertion: insertion, document: replacement, audit: auditBytes)
  }

  private func publish(
    base: String, path: String, replacement: Data, auditBytes: Data,
    title: String = "Core memory direct management"
  ) throws
    -> MemoryManagementResult
  {
    let auditRef = "refs/memory-management/changes/\(SourceDigest(bytes: auditBytes).rawValue)"
    let checkout = try git.reviewCheckout()
    return try withState(checkout: checkout) { state in
      let witness = try checkout.witness()
      guard witness.head == Data((witness.commit + "\n").utf8) else {
        throw MemoryError(
          "checkout is attached; run /mem-prepare and confirm checkout preparation, then retry the requested change"
        )
      }
      try checkout.lock(state: state, detachedHead: witness.head)
      guard try checkout.witness(isLocked: true) == witness, witness.main == base else {
        throw MemoryError("checkout or approved base changed; list entries again")
      }
      let commit = try store.reviewCommit(
        base: base, path: path, replacement: replacement,
        message: Data((title + "\n\n").utf8) + auditBytes + Data([10]))
      _ = try store.reviewSnapshot(base: commit)
      try store.publishCheckedMemoryCommit(
        commit: commit, base: base, auditRef: auditRef, checkout: witness)
      return MemoryManagementResult(
        base: base, entries: [], commit: commit, auditRef: auditRef,
        message:
          "Requested change committed. Existing sessions keep their saved memory snapshot. Changes load in a new session. This is not dream candidate approval."
      )
    }
  }

  package func reviewCatalog(
    cwd: URL, deviceKey: String? = nil, projectBindings: [String: String] = [:]
  ) throws -> MemoryManagementResult {
    let catalog = try execute(MemoryManagementRequest(operation: .list))
    try MemoryScopeConfiguration.validate(deviceKey: deviceKey, projectBindings: projectBindings)
    let key = try MemoryStore.projectKey(cwd: cwd, projectBindings: projectBindings)
    let paths = MemoryScopeConfiguration.paths(
      projectKeys: key.map { [$0] } ?? [], deviceKey: deviceKey)
    return MemoryManagementResult(
      base: catalog.base,
      entries: catalog.entries.filter {
        paths.contains($0.path)
          && MemoryDocument.isMemoryContent(Data($0.expected.utf8))
      }, commit: nil, auditRef: nil, message: catalog.message)
  }

  package static func isReviewDue(_ reviewed: String?, date: Date) -> Bool {
    guard let reviewed, let instant = ISO8601DateFormatter().date(from: reviewed) else {
      return true
    }
    return date.timeIntervalSince(instant) >= 30 * 86_400
  }

  package func confirmReviewed(base: String, entry: ManagedMemoryEntry, date: Date = Date()) throws
    -> MemoryManagementResult
  {
    guard try store.approvedCommit() == base, date.timeIntervalSince1970.isFinite else {
      throw MemoryError("approved base changed; open native review again")
    }
    let snapshot = try store.reviewSnapshot(base: base)
    let rows = snapshot.reviewEntries()
    let identities = rows.compactMap { $0.entry.identity }
    guard Set(identities).count == identities.count,
      let target = rows.first(where: { $0.path == entry.path && $0.entry.locator == entry.locator }
      ),
      target.entry.isMutable, target.entry.bytes == Data(entry.expected.utf8)
    else { throw MemoryError("entry changed or is not mutable; open native review again") }
    let instant = try MemoryDocument.ReviewInstant(ISO8601DateFormatter().string(from: date))
    let after = try MemoryDocument.reviewedBytes(
      target.entry.bytes, identity: target.entry.identity ?? UUID(), instant: instant)
    guard var replacement = snapshot.documents.first(where: { $0.path == entry.path })?.bytes else {
      throw MemoryError("approved document is missing")
    }
    replacement.replaceSubrange(entry.locator.start..<entry.locator.end, with: after)
    let auditBytes = try JSONSerialization.data(
      withJSONObject: [
        "origin": "native-approved-entry-review", "base": base, "path": entry.path,
        "before": entry.expected, "after": String(decoding: after, as: UTF8.self),
        "reviewed": instant.rawValue,
      ], options: [.sortedKeys, .withoutEscapingSlashes])
    return try publish(
      base: base, path: entry.path, replacement: replacement, auditBytes: auditBytes,
      title: "Core memory approved entry review")
  }

  package func checkoutPreview() throws -> MemoryReviewCheckoutPreview {
    let checkout = try git.reviewCheckout()
    return try withState(checkout: checkout) { _ in
      let witness = try checkout.witness()
      return MemoryReviewCheckoutPreview(
        commit: witness.commit, main: witness.main,
        isDetachRequired: witness.head == Data("ref: refs/heads/main\n".utf8),
        digest: SourceDigest(bytes: try MemoryReviewEncoding.encode(witness)), witness: witness)
    }
  }

  package func confirmDetach(_ preview: MemoryReviewCheckoutPreview) throws {
    guard preview.isDetachRequired else { throw MemoryError("checkout is already detached") }
    let checkout = try git.reviewCheckout()
    try withState(checkout: checkout) { state in
      try checkout.lock(state: state, detachedHead: Data((preview.commit + "\n").utf8))
      try afterCheckoutLocks?()
      guard try checkout.witness(isLocked: true) == preview.witness else {
        throw MemoryError("checkout changed; run /mem-prepare again")
      }
      try checkout.detach(preview.witness)
    }
  }

  private func withState<T>(
    checkout: ReviewCheckoutDirectory, operation: (DreamStateDirectory) throws -> T
  )
    throws -> T
  {
    try checkout.withLeaseState(operation)
  }
}
