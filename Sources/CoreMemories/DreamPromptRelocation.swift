import Foundation

package struct DreamSourceRoles: Codable, Equatable, Sendable {
  package let isSnippetsPresent: Bool
  package let isPromptsPresent: Bool

  package init(isSnippetsPresent: Bool, isPromptsPresent: Bool) {
    self.isSnippetsPresent = isSnippetsPresent
    self.isPromptsPresent = isPromptsPresent
  }

  var strippingCount: Int { (isSnippetsPresent ? 1 : 0) + (isPromptsPresent ? 1 : 0) }
  var promptsOffset: Int { isSnippetsPresent ? 1 : 0 }

  func sources(_ roots: [URL]) throws -> DreamFreshSources {
    guard roots.count == 2 + strippingCount else { throw DreamRunError.unsafeState }
    return DreamFreshSources(
      sessions: roots[0], memory: roots[1], snippets: isSnippetsPresent ? roots[2] : nil,
      prompts: isPromptsPresent ? roots[2 + promptsOffset] : nil)
  }
}

package struct DreamFreshSources: Sendable {
  package let sessions: URL
  package let memory: URL
  package let snippets: URL?
  package let prompts: URL?
  package var admittedViews: [DreamAdmittedView] = []
}

package enum PromptRelocationAuthorization: String, Codable, Sendable {
  case explicitCaller
}

struct PromptTemplateInventory: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    let name: String
    let byteCount: Int
    let sha256: String
  }

  let entryCount: Int
  let rawByteCount: Int
  let digest: String
  let entries: [Entry]

  init(inputs: [PreparationStrippingInput], maximumBytes: Int) throws {
    guard inputs.count <= 10_000 else { throw DreamRunError.limitExceeded }
    let names = inputs.map(\.name)
    guard names == names.sorted(), Set(names.map { Data($0.utf8) }).count == names.count else {
      throw DreamRunError.corruption
    }
    var bytes = Data("templates\0".utf8)
    var total = 0
    var entries: [Entry] = []
    for input in inputs {
      guard input.kind == "templates", !input.name.isEmpty, input.name.utf8.count <= 255,
        !input.name.contains("/"), !input.name.contains("\0"),
        input.name.lowercased().hasSuffix(".md"),
        input.bytes.count <= maximumBytes - total
      else { throw DreamRunError.limitExceeded }
      total += input.bytes.count
      bytes.append(Data("\(input.name.utf8.count):\(input.name)\(input.bytes.count):".utf8))
      bytes.append(input.bytes)
      entries.append(
        Entry(
          name: input.name, byteCount: input.bytes.count,
          sha256: SourceDigest(bytes: input.bytes).rawValue))
    }
    entryCount = inputs.count
    rawByteCount = total
    digest = SourceDigest(bytes: bytes).rawValue
    self.entries = entries
  }

  var display: Self {
    Self(
      entryCount: entryCount, rawByteCount: rawByteCount, digest: digest,
      entries: entries.map {
        Entry(
          name: MemoryStore.safeReviewDisplay($0.name),
          byteCount: $0.byteCount, sha256: $0.sha256)
      })
  }

  private init(entryCount: Int, rawByteCount: Int, digest: String, entries: [Entry]) {
    self.entryCount = entryCount
    self.rawByteCount = rawByteCount
    self.digest = digest
    self.entries = entries
  }
}

struct PromptRelocationPayload: Codable, Equatable, Sendable {
  struct Store: Codable, Equatable, Sendable {
    let statePath: String
    let stateVolume: String
    let stateInode: UInt64
    let sourceBinding: String
    let rootHash: String
    let repositoryPath: String
    let repositoryVolume: String
    let repositoryInode: UInt64
  }

  struct Baseline: Codable, Equatable, Sendable {
    let runID: String
    let generation: UInt64
    let admissionHash: String
    let predecessorHash: String
    let inputHash: String
    let contextHash: String
    let requestHash: String
    let completedGenerationHash: String?
    let completionHash: String?
  }

  struct Anchor: Codable, Equatable, Sendable {
    let generation: UInt64
    let generationHash: String
    let currentAdmissionHash: String?
  }

  struct Coverage: Codable, Equatable, Sendable {
    struct OtherInventory: Codable, Equatable, Sendable {
      let runID: String
      let templateDigest: String
    }
    let claim: String
    let isCompleted: Bool
    let isNewerCompletedCapturePresent: Bool
    let differingInventories: [OtherInventory]
    let limitations: [String]
  }

  let schemaVersion: Int
  let policyVersion: Int
  let kind: String
  let store: Store
  let role: String
  let roles: DreamSourceRoles
  let strippingOffset: Int
  let registeredOriginal: String
  let registeredCanonical: String
  let replacement: String
  let baseline: Baseline
  let anchor: Anchor
  let inventory: PromptTemplateInventory
  let coverage: Coverage
  let isRecordAbsent: Bool

  var fingerprint: SourceDigest {
    get throws {
      var bytes = Data("pi-core-memories/prompt-relocation-preview/v1\0".utf8)
      bytes.append(try DreamRunEncoding.encode(self))
      return SourceDigest(bytes: bytes)
    }
  }
}

struct PromptRelocationRecord: Codable, Equatable, Sendable {
  static let name = "prompt-relocation.json"
  static let maximumBytes = 1_048_576
  let payload: PromptRelocationPayload
  let previewHash: String
  let authorization: PromptRelocationAuthorization

  func encoded() throws -> Data {
    let bytes = try DreamRunEncoding.encode(self)
    guard bytes.count <= Self.maximumBytes else { throw DreamRunError.limitExceeded }
    return bytes
  }

  static func decode(_ bytes: Data) throws -> Self {
    let record: Self
    do { record = try JSONDecoder().decode(Self.self, from: bytes) } catch {
      throw MemoryError("corrupt prompt relocation record")
    }
    guard record.payload.schemaVersion == 1, record.payload.policyVersion == 1 else {
      throw MemoryError("unsupported prompt relocation record")
    }
    guard bytes == (try record.encoded()), record.payload.role == "prompts",
      record.payload.kind == "prompt-source-relocation", record.payload.isRecordAbsent,
      record.previewHash == (try record.payload.fingerprint.rawValue)
    else { throw MemoryError("corrupt prompt relocation record") }
    return record
  }
}

package struct PromptRelocationPreview: Encodable, Sendable {
  package let registeredOriginal: String
  package let registeredCanonical: String
  package let replacement: String
  let store: PromptRelocationPayload.Store
  let baseline: PromptRelocationPayload.Baseline
  let anchor: PromptRelocationPayload.Anchor
  let roles: DreamSourceRoles
  let coverage: PromptRelocationPayload.Coverage
  let baselineInventory: PromptTemplateInventory
  let replacementInventory: PromptTemplateInventory
  package let mismatches: [String]
  package let isCompatible: Bool
  package let previewHash: String?

  init(payload: PromptRelocationPayload, target: PromptTemplateInventory, mismatches: [String])
    throws
  {
    registeredOriginal = MemoryStore.safeReviewDisplay(payload.registeredOriginal)
    registeredCanonical = MemoryStore.safeReviewDisplay(payload.registeredCanonical)
    replacement = MemoryStore.safeReviewDisplay(payload.replacement)
    store = .init(
      statePath: MemoryStore.safeReviewDisplay(payload.store.statePath),
      stateVolume: payload.store.stateVolume, stateInode: payload.store.stateInode,
      sourceBinding: payload.store.sourceBinding, rootHash: payload.store.rootHash,
      repositoryPath: MemoryStore.safeReviewDisplay(payload.store.repositoryPath),
      repositoryVolume: payload.store.repositoryVolume,
      repositoryInode: payload.store.repositoryInode)
    baseline = payload.baseline
    anchor = payload.anchor
    roles = payload.roles
    coverage = payload.coverage
    baselineInventory = payload.inventory.display
    replacementInventory = target.display
    self.mismatches = mismatches.map(MemoryStore.safeReviewDisplay)
    isCompatible = mismatches.isEmpty
    previewHash = mismatches.isEmpty ? try payload.fingerprint.rawValue : nil
  }
}

package struct PromptRelocationReceipt: Encodable, Sendable {
  package let previewHash: String
  package let replacement: String
  package let recordName: String
}
