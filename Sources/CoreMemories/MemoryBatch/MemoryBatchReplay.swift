import Foundation

struct MemoryBatchAttempt: Codable, Sendable {
  let manifest: MemoryBatchManifest
  let commit: String
  let tree: String
}

package struct MemoryBatchReceipt: Codable, Sendable {
  package let saveID: String
  package let draftID: UUID
  package let revision: UInt64
  package let base: String
  package let commit: String?
  package let auditRef: String?
}

package struct MemoryBatchRecoveryRequired: Error, CustomStringConvertible, Sendable {
  package let saveID: String
  package let details: String
  package var description: String { "Save outcome requires recovery (\(saveID)): \(details)" }
}

package enum MemoryBatchSaveResult: Sendable {
  case saved(MemoryBatchReceipt)
  case decisionsSaved(MemoryBatchReceipt)
  case savedNeedsRecovery(MemoryBatchReceipt, details: String)
  case outcomeUnknown(saveID: String, details: String)
}

enum MemoryBatchReplay {
  static let title = Data("Core memory batch Save\n\n".utf8)

  static func manifest(_ draft: MemoryDraft, composition: MemoryBatchComposition) throws
    -> MemoryBatchManifest
  {
    MemoryBatchManifest(
      schemaVersion: 1, compositionVersion: 1, saveID: try memoryBatchDigest(draft),
      intentDigest: try memoryBatchDigest(draft.batch), draft: draft, effects: composition.effects,
      documentDigests: composition.replacements.mapValues { SourceDigest(bytes: $0).rawValue })
  }

  static func message(_ manifest: MemoryBatchManifest) throws -> Data {
    title + (try MemoryReviewEncoding.encode(manifest)) + Data([10])
  }

  static func read(_ commit: String, git: Git) throws -> MemoryBatchManifest {
    guard MemoryStore.isFullOID(commit) else { throw DreamRunError.corruption }
    let raw = try git.data(["cat-file", "commit", commit])
    guard raw.count <= MemoryReviewEncoding.maximumStateBytes,
      let split = raw.range(of: Data([10, 10]))
    else { throw DreamRunError.corruption }
    let message = Data(raw[split.upperBound...])
    guard message.starts(with: title), message.last == 10 else { throw DreamRunError.corruption }
    return try MemoryReviewEncoding.decode(
      MemoryBatchManifest.self, bytes: Data(message.dropFirst(title.count).dropLast()))
  }

  static func validate(
    _ manifest: MemoryBatchManifest, composition: MemoryBatchComposition, commit: String?,
    store: MemoryStore
  ) throws {
    let expected = try Self.manifest(manifest.draft, composition: composition)
    guard try memoryBatchDigest(manifest) == memoryBatchDigest(expected) else {
      throw DreamRunError.corruption
    }
    guard let commit else {
      guard composition.effects.isEmpty, composition.replacements.isEmpty,
        manifest.draft.batch!.items.allSatisfy({ item in
          if case .candidate(let candidate) = item.intent {
            return candidate.choice != .accept && candidate.amendment == nil
          }
          return false
        })
      else { throw DreamRunError.corruption }
      return
    }
    guard !composition.effects.isEmpty, MemoryStore.isFullOID(commit) else {
      throw DreamRunError.corruption
    }
    let git = store.reviewGit
    let raw = try git.data(["cat-file", "commit", commit])
    guard let split = raw.range(of: Data([10, 10])) else { throw DreamRunError.corruption }
    let headers = String(decoding: raw[..<split.lowerBound], as: UTF8.self).split(separator: "\n")
    guard
      headers.filter({ $0.hasPrefix("parent ") }) == [
        Substring("parent " + manifest.draft.baseCommit)
      ],
      try Data(raw[split.upperBound...]) == message(manifest)
    else { throw DreamRunError.corruption }
    let before = try store.reviewSnapshot(base: manifest.draft.baseCommit)
    let after = try store.reviewSnapshot(base: commit)
    var layout = Dictionary(
      uniqueKeysWithValues: before.layoutEntries.map { ($0.path, ($0.mode, $0.blob)) })
    for (path, bytes) in composition.replacements {
      layout[path] = (
        "100644", try git.text(["hash-object", "--stdin", "--no-filters"], input: bytes)
      )
    }
    guard after.layoutEntries.count == layout.count,
      after.layoutEntries.allSatisfy({ entry in
        layout[entry.path].map { $0.0 == entry.mode && $0.1 == entry.blob } ?? false
      }),
      try git.committedChangedPathBytes(from: before.base, to: commit)
        == Data((composition.replacements.keys.sorted().joined(separator: "\0") + "\0").utf8)
    else { throw MemoryError("batch receipt tree differs from the complete reviewed composition") }
  }

  static func directCommit(_ ref: String, git: Git) throws -> String? {
    let rows = try git.text([
      "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", ref,
    ])
    .split(separator: "\n")
    guard !rows.isEmpty else { return nil }
    guard rows.count == 1 else { throw DreamRunError.corruption }
    let fields = rows[0].split(separator: "\0", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0] == Substring(ref), fields[2].isEmpty,
      MemoryStore.isFullOID(String(fields[1])),
      try git.text(["cat-file", "-t", String(fields[1])]) == "commit"
    else { throw MemoryError("batch receipt must be an exact direct commit ref") }
    return String(fields[1])
  }

  static func isAncestor(_ commit: String, of main: String, git: Git) throws -> Bool {
    let result = try git.run(["merge-base", "--is-ancestor", commit, main])
    guard result.status == 0 || result.status == 1 else { throw DreamRunError.corruption }
    return result.status == 0
  }

  static func receipt(_ manifest: MemoryBatchManifest, commit: String?) -> MemoryBatchReceipt {
    MemoryBatchReceipt(
      saveID: manifest.saveID, draftID: manifest.draft.draftID, revision: manifest.draft.revision,
      base: manifest.draft.baseCommit, commit: commit,
      auditRef: commit.map { _ in "refs/memory-batches/\(manifest.saveID)" })
  }
}
