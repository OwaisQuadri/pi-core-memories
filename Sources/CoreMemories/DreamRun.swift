import Darwin
import Foundation

private struct DreamTiming: Codable {
  var schemaVersion: Int = 2
  let provider: String
  let modelID: String
  let thinkingLevel: String
  let records: Int
  let inputBytes: Int
  let seconds: Double
}

public struct DreamSelectedCall: Equatable, Sendable {
  public let provider: String
  public let modelID: String
  public let thinkingLevel: String

  public init(provider: String, modelID: String, thinkingLevel: String) throws {
    for value in [provider, modelID, thinkingLevel] {
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        value.utf8.count <= 256,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { throw DreamRunError.invalidSelection }
    }
    self.provider = provider
    self.modelID = modelID
    self.thinkingLevel = thinkingLevel
  }
}

struct DreamRunContext: Sendable {
  public let selection: DreamSelectedCall
  public let currentApprovedBase: String

  public init(selection: DreamSelectedCall, currentApprovedBase: String) throws {
    guard [40, 64].contains(currentApprovedBase.utf8.count),
      currentApprovedBase.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw DreamRunError.invalidBase }
    self.selection = selection
    self.currentApprovedBase = currentApprovedBase
  }
}

public struct DreamRunLimits: Sendable {
  public let maximumFrozenBytes: Int
  public let maximumResponseBytes: Int
  public let maximumPositions: Int
  public let maximumStateBytes: Int

  public init(
    maximumFrozenBytes: Int = 33_554_432, maximumResponseBytes: Int = 262_144,
    maximumPositions: Int = 32_768, maximumStateBytes: Int = 1_073_741_824
  ) throws {
    guard maximumFrozenBytes > 0, maximumResponseBytes > 0, maximumPositions > 0,
      maximumStateBytes > 0,
      maximumResponseBytes <= (Int.max - DreamRunEncoding.maximumMetadataBytes) / 6
    else { throw DreamRunError.limitExceeded }
    self.maximumFrozenBytes = maximumFrozenBytes
    self.maximumResponseBytes = maximumResponseBytes
    self.maximumPositions = maximumPositions
    self.maximumStateBytes = maximumStateBytes
  }

}

public struct DreamCompletedResponse: Sendable {
  public let text: String

  public init(text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DreamRunError.invalidResponse
    }
    self.text = text
  }
}

public struct DurableDreamResponse: Sendable {
  public let run: FrozenDreamRun
  public let response: DreamCompletedResponse
  public let responseHash: SourceDigest
  public let isReplay: Bool
  public let isBaseCurrent: Bool
}

public enum DreamRequestRole: String, Sendable, Codable {
  case system, user
}

public struct DreamRequestMessage: Sendable, Codable, Equatable {
  public let role: DreamRequestRole
  public let text: String
  public let timestampMilliseconds: Int64
}

public struct DreamModelRequest: Sendable {
  public let runID: String
  public let generation: UInt64
  public let inputHash: SourceDigest
  public let contextHash: SourceDigest
  public let requestHash: SourceDigest
  public let selection: DreamSelectedCall
  public let systemPrompt: String
  public let messages: [DreamRequestMessage]
}

public struct DreamProposalReceipt: Sendable {
  public let planHash: SourceDigest
  public let ref: String
  public let commit: String
  public let base: String
  public let path: String
  public let sources: [PrimaryTextID]
  public let contradictions: String
}

public struct DreamCompletionReport: Sendable {
  public let runID: String
  public let predecessorGeneration: UInt64
  public let generation: UInt64
  public let approvedBase: String
  public let proposals: [DreamProposalReceipt]
  public let notes: [DreamDecisionNote]
  public let isBacklog: Bool
  public let isRecovered: Bool
}

package struct VerifiedDreamReviewCandidates: Sendable {
  package let runID: String
  package let generation: UInt64
  package let admissionHash: SourceDigest
  package let completionHash: SourceDigest
  package let decisionsHash: SourceDigest
  package let changes: [AtomicMemoryChange]
  package let receipts: [DreamProposalReceipt]
  package let limitations: [String]
  let recoveryCheckpointHash: SourceDigest?
  let recoveryCheckpoint: DreamRunEncoding.RecoveryCheckpoint?
}

package struct SavedSuggestionSummary: Sendable {
  package let change: AtomicMemoryChange
  package let blocker: String?
}

package struct SavedDreamRecoveryPreview: Sendable {
  package let runID: String
  package let suggestions: [SavedSuggestionSummary]
  fileprivate let witness: UUID
  fileprivate let fingerprint: SourceDigest
}

public struct DreamPendingReport: Sendable {
  public let runID: String
  public let generation: UInt64
  public let approvedBase: String
  public let inputHash: SourceDigest
  public let contextHash: SourceDigest
  public let requestHash: SourceDigest
  public let proposals: [DreamProposalReceipt]
  public let reason: DreamPendingReason
  public let validationError: DreamDecisionError?
  public let callSelection: DreamSelectedCall?
}

public enum DreamTransactionResult: Sendable {
  case completed(DreamCompletionReport)
  case pending(DreamPendingReport)
  case noNewRecords(generation: UInt64, unfinishedTails: [UnfinishedSessionTail])
}

public enum DreamPendingReason: String, Sendable {
  case interruptedCall, cancelled, callbackFailure, invalidDecision, staleUnpublishedPlans
}

public enum DreamResumeAction: Sendable {
  case inspectOrContinue, retryInterruptedCall, replaceInvalidResponse
}

public enum DreamRunError: Error, Equatable, Sendable, CustomStringConvertible {
  case busy, unsafeState, unsupportedSchema, corruption, missingPayload, staleGeneration
  case limitExceeded, persistenceFailure, invalidSelection, invalidBase, invalidResponse
  case replacementUnavailable
  case nativeReviewLimitation(String)

  public var description: String {
    switch self {
    case .busy: "dream writer is busy"
    case .unsafeState: "unsafe dream state"
    case .unsupportedSchema:
      "unsupported dream storage schema; schema-one responses lack pinned decision context"
    case .corruption: "corrupt dream state"
    case .missingPayload: "missing authoritative dream state or payload"
    case .staleGeneration: "stale dream generation"
    case .limitExceeded: "dream storage limit exceeded"
    case .persistenceFailure: "dream persistence failed"
    case .invalidSelection: "invalid dream selection"
    case .invalidBase: "invalid approved base"
    case .invalidResponse: "completed dream response must be nonempty"
    case .replacementUnavailable: "dream replacement requires a saved invalid reply"
    case .nativeReviewLimitation(let reason): "native review unavailable: \(reason)"
    }
  }
}

enum DreamPersistenceEvent: Equatable {
  case beforeWrite(String)
  case afterWriteChunk(String)
  case afterWrite(String)
  case beforeFileSync(String)
  case afterFileSync(String)
  case beforeInstall(String)
  case afterInstall(String)
  case beforeDirectorySync(String)
  case afterDirectorySync(String)
}

public final class DreamRunStore {
  private let root: DreamStateDirectory
  private let reviewStateURL: URL
  private let configuredRoots: [URL]
  private let suppliedRoots: [URL]
  private let memoryRepository: URL
  private let globalAgents: URL?
  private let bindingBytes: Data
  private let bindingHash: SourceDigest
  private let limits: DreamRunLimits
  private let deviceKey: String?
  private let projectBindings: [String: String]
  private let operationLock = NSLock()
  private var recoveryWitnesses: [UUID: SourceDigest] = [:]
  var persistenceFault: ((DreamPersistenceEvent) throws -> Void)?
  var clock: () -> Date = { Date() }
  var isCancelled: () -> Bool = { false }
  var beforePublication: ((String) throws -> Void)?
  var recoveryCount = 0
  var beforeFinalReport: (() throws -> Void)?
  var writeChunkBytes: Int = Int.max
  var writeCall: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
  var syncCall: (Int32) -> Int32 = { Darwin.fsync($0) }
  var installCall: (Int32, String, String, Bool) -> Int32 = {
    directory, temporary, name, isReplacing in
    if isReplacing { return Darwin.renameat(directory, temporary, directory, name) }
    return Darwin.renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL))
  }

  static func isManagedSnippets(_ path: String, state: URL, sessions: URL) -> Bool {
    let logical = sessions.deletingLastPathComponent()
      .appendingPathComponent("extensions/prompt-snippets/snippets").path
    if path == logical { return true }
    guard state.path.hasSuffix("/.local/state/pi-core-memories"),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { return false }
    let home = state.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let prefix = home.appendingPathComponent(".cache/tool-sync/installs").path + "/"
    guard path.hasPrefix(prefix) else { return false }
    let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 9 && !parts[0].isEmpty
      && parts[0].allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
      }
      && parts[1...3].joined(separator: "/") == "home/.local/lib"
      && ["agents-runtime", "agents-resources"].contains(String(parts[4]))
      && parts[5...8].joined(separator: "/") == "pi/extensions/prompt-snippets/snippets"
  }

  public convenience init(
    stateRoot: URL, sessionsRoot: URL, memoryRepository: URL, strippingRoots: [URL],
    globalAgents: URL? = nil, deviceKey: String? = nil, projectBindings: [String: String] = [:],
    limits: DreamRunLimits = try! DreamRunLimits(),
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws {
    try self.init(
      stateRoot: stateRoot, sessionsRoot: sessionsRoot, memoryRepository: memoryRepository,
      strippingRoots: strippingRoots, globalAgents: globalAgents, deviceKey: deviceKey,
      projectBindings: projectBindings, limits: limits, isCancelled: isCancelled, isReadOnly: false)
  }

  package init(
    stateRoot: URL, sessionsRoot: URL, memoryRepository: URL, strippingRoots: [URL],
    globalAgents: URL? = nil, deviceKey: String? = nil, projectBindings: [String: String] = [:],
    limits: DreamRunLimits = try! DreamRunLimits(),
    isCancelled: @escaping @Sendable () -> Bool = { false }, isReadOnly: Bool
  ) throws {
    try MemoryScopeConfiguration.validate(deviceKey: deviceKey, projectBindings: projectBindings)
    self.deviceKey = deviceKey
    self.projectBindings = projectBindings
    guard
      ([stateRoot, sessionsRoot, memoryRepository] + strippingRoots
        + (globalAgents.map { [$0] } ?? [])).allSatisfy({
          $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0")
        })
    else { throw DreamRunError.unsafeState }
    let state = stateRoot
    guard !state.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw DreamRunError.unsafeState
    }
    var ancestor = state
    while !FileManager.default.fileExists(atPath: ancestor.path) {
      guard ancestor.path != "/" else { throw DreamRunError.unsafeState }
      ancestor.deleteLastPathComponent()
    }
    guard
      try Git(repo: ancestor, environment: ProcessInfo.processInfo.environment)
        .commonDirectory() == nil
    else { throw DreamRunError.unsafeState }
    let suppliedRoots = [sessionsRoot, memoryRepository] + strippingRoots
    let isEstablished =
      FileManager.default.fileExists(
        atPath: state.appendingPathComponent("root.json").path)
      || (try? FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty) == false
    let storedDirectory: DreamStateDirectory?
    let storedBytes: Data?
    let storedBinding: RootBinding?
    if isEstablished,
      FileManager.default.fileExists(atPath: state.appendingPathComponent("root.json").path)
    {
      let directory = try DreamStateDirectory.openRoot(state, isCreating: !isReadOnly)
      let bytes = try directory.read("root.json", maximum: DreamRunEncoding.maximumMetadataBytes)
      let binding = try DreamRunEncoding.decode(RootBinding.self, bytes: bytes)
      let accepted = [binding.sessions, binding.memory] + binding.stripping
      let requested = binding.originalRoots ?? accepted
      guard accepted.count == suppliedRoots.count, requested.count == accepted.count,
        zip(requested, suppliedRoots).enumerated().allSatisfy({ index, pair in
          Data(pair.0.utf8) == Data(pair.1.path.utf8)
            || (index >= 2
              && Self.isManagedSnippets(pair.0, state: state, sessions: sessionsRoot)
              && Self.isManagedSnippets(pair.1.path, state: state, sessions: sessionsRoot))
        }),
        accepted.allSatisfy({
          $0.hasPrefix("/") && !$0.contains("\0")
            && !$0.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }),
        binding.globalAgents.map({ Data($0.utf8) }) == globalAgents.map({ Data($0.path.utf8) }),
        bytes == (try DreamRunEncoding.encode(binding))
      else { throw DreamRunError.unsafeState }
      storedDirectory = directory
      storedBytes = bytes
      storedBinding = binding
    } else {
      storedDirectory = nil
      storedBytes = nil
      storedBinding = nil
    }
    var sources: [URL]
    if let storedBinding {
      sources = ([storedBinding.sessions, storedBinding.memory] + storedBinding.stripping)
        .map { URL(fileURLWithPath: $0) }
      for index in sources.indices where index >= 2 {
        if Self.isManagedSnippets(sources[index].path, state: state, sessions: sessionsRoot),
          Self.isManagedSnippets(suppliedRoots[index].path, state: state, sessions: sessionsRoot)
        {
          let active = try Self.canonicalExisting(suppliedRoots[index])
          guard Self.isManagedSnippets(active.path, state: state, sessions: sessionsRoot) else {
            throw DreamRunError.unsafeState
          }
          sources[index] = active
        }
      }
    } else {
      sources = try suppliedRoots.map {
        isEstablished ? $0 : try Self.canonicalExisting($0.standardizedFileURL)
      }
    }
    let canonicalAncestor = try Self.canonicalExisting(ancestor)
    let suffix = state.path.dropFirst(ancestor.path == "/" ? 0 : ancestor.path.count)
    let canonicalState = canonicalAncestor.appendingPathComponent(String(suffix))
    for source in sources {
      guard !Self.isWithin(canonicalState, source), !Self.isWithin(source, canonicalState) else {
        throw DreamRunError.unsafeState
      }
    }
    configuredRoots = sources
    self.suppliedRoots = suppliedRoots
    self.memoryRepository = sources[1]
    self.globalAgents = globalAgents
    root = try storedDirectory ?? DreamStateDirectory.openRoot(state, isCreating: !isReadOnly)
    reviewStateURL = state
    self.limits = limits
    self.isCancelled = isCancelled
    let original =
      zip(sources, suppliedRoots).contains { pair in
        Data(pair.0.path.utf8) != Data(pair.1.path.utf8)
      } ? suppliedRoots.map(\.path) : nil
    bindingBytes =
      try storedBytes
      ?? DreamRunEncoding.encode(
        RootBinding(
          schemaVersion: 2, sessions: sources[0].path, memory: sources[1].path,
          stripping: sources.dropFirst(2).map(\.path), globalAgents: globalAgents?.path,
          originalRoots: original))
    guard bindingBytes.count <= DreamRunEncoding.maximumMetadataBytes else {
      throw DreamRunError.limitExceeded
    }
    bindingHash = SourceDigest(bytes: bindingBytes)
  }

  package var reviewStateRoot: URL { reviewStateURL }

  package var historicalSourceIdentities: (sessions: URL, stripping: [URL]) {
    get throws {
      let binding = try DreamRunEncoding.decode(RootBinding.self, bytes: bindingBytes)
      let original =
        binding.originalRoots ?? ([binding.sessions, binding.memory] + binding.stripping)
      return (
        URL(fileURLWithPath: original[0]), original.dropFirst(2).map { URL(fileURLWithPath: $0) }
      )
    }
  }

  package func reviewSourceBinding(isLegacy: Bool = false) throws -> SourceDigest {
    var held = stat()
    var named = stat()
    guard fstat(root.descriptor, &held) == 0, lstat(reviewStateURL.path, &named) == 0,
      held.st_dev == named.st_dev, held.st_ino == named.st_ino
    else { throw DreamRunError.unsafeState }
    try Self.validateStateIdentity(named, isDirectory: true)
    guard try root.read("root.json", maximum: DreamRunEncoding.maximumMetadataBytes) == bindingBytes
    else { throw DreamRunError.corruption }
    let volume =
      try isLegacy ? String(held.st_dev) : MemoryReviewEncoding.volumeUUID(at: reviewStateURL)
    return SourceDigest(
      bytes: Data(
        "\(reviewStateURL.path)\0\(volume)\0\(held.st_ino)\0\(bindingHash.rawValue)".utf8))
  }

  public var acceptedSources: (sessions: URL, memory: URL, stripping: [URL]) {
    (configuredRoots[0], configuredRoots[1], Array(configuredRoots.dropFirst(2)))
  }

  package func verifiedCompletedReviewCandidates() throws -> [VerifiedDreamReviewCandidates] {
    try withVerifiedReviewCandidates { $0 }
  }

  func withVerifiedReviewCandidates<T>(
    _ operation: ([VerifiedDreamReviewCandidates]) throws -> T
  ) throws -> T {
    guard operationLock.try() else { throw DreamRunError.busy }
    defer { operationLock.unlock() }
    let lock = try root.openReadLock()
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DreamRunError.busy }
    var bundles: [VerifiedDreamReviewCandidates] = []
    do {
      try root.verifyLock(lock)
      _ = try root.retainedBytes(maximum: limits.maximumStateBytes, isDreamAuthority: true)
      guard
        try root.read("root.json", maximum: DreamRunEncoding.maximumMetadataBytes) == bindingBytes
      else {
        throw DreamRunError.unsafeState
      }
      _ = try loadChain(completed: { bundles.append($0) })
    } catch DreamRunError.busy { throw DreamRunError.busy } catch {
      throw DreamRunError.nativeReviewLimitation("saved completion verification failed: \(error)")
    }
    return try operation(bundles)
  }

  package func previewSavedRecovery(runID: String) throws -> SavedDreamRecoveryPreview {
    try withRecoveryLock {
      recoveryWitnesses.removeAll()
      let proof = try savedRecoveryProof(runID: runID)
      let witness = UUID()
      recoveryWitnesses[witness] = proof.fingerprint
      return SavedDreamRecoveryPreview(
        runID: runID, suggestions: proof.suggestions, witness: witness,
        fingerprint: proof.fingerprint)
    }
  }

  package func confirmSavedRecovery(_ preview: SavedDreamRecoveryPreview) throws
    -> DreamTransactionResult
  {
    try withRecoveryLock {
      guard recoveryWitnesses.removeValue(forKey: preview.witness) == preview.fingerprint else {
        throw MemoryError("saved suggestions confirmation is stale")
      }
      let proof = try savedRecoveryProof(runID: preview.runID)
      guard proof.fingerprint == preview.fingerprint, !isCancelled() else {
        throw MemoryError("saved suggestions changed; prepare again")
      }
      let memory = try MemoryStore(repo: memoryRepository)
      try memory.publishSavedProposals(proof.outcome.plans, observedMain: proof.main) {
        try self.install(
          proof.checkpoint, name: "recovery.json", directory: proof.sealed.directory)
      }
      return try finish(proof.sealed, chain: proof.chain, isRecovered: true, isCommitted: false)
    }
  }

  private func withRecoveryLock<T>(_ body: () throws -> T) throws -> T {
    guard operationLock.try() else { throw DreamRunError.busy }
    defer { operationLock.unlock() }
    let lock = try root.openReadLock()
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DreamRunError.busy }
    try root.verifyLock(lock)
    _ = try root.retainedBytes(maximum: limits.maximumStateBytes, isDreamAuthority: true)
    _ = try reviewSourceBinding()
    return try body()
  }

  private struct SavedRecoveryProof {
    let sealed: SealedRun
    let chain: SuccessfulChain
    let outcome: Outcome
    let main: String
    let checkpoint: DreamRunEncoding.RecoveryCheckpoint
    let fingerprint: SourceDigest
    let suggestions: [SavedSuggestionSummary]
  }

  private func snapshotHash(_ snapshot: ApprovedDecisionSnapshot) -> String {
    var bytes = Data((snapshot.base + "\0" + snapshot.layoutHash.rawValue).utf8)
    for document in snapshot.documents {
      bytes.append(
        Data(("\0" + document.path + "\0" + (document.digest?.rawValue ?? "absent")).utf8))
    }
    return SourceDigest(bytes: bytes).rawValue
  }

  private func recoveryCheckpoint(
    _ sealed: SealedRun, outcome: Outcome, main: String
  ) throws -> DreamRunEncoding.RecoveryCheckpoint {
    var status = stat()
    guard lstat(memoryRepository.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
      throw DreamRunError.unsafeState
    }
    var artifacts: [[String]] = []
    for name in try sealed.directory.names().sorted()
    where name == "input.json" || name == "context.json" || name == "request.json"
      || name == "response.json" || name == "call-started.json"
      || name.hasPrefix("replacement-") || name.hasPrefix("rejected-")
    {
      let bytes = try sealed.directory.read(
        name, maximum: max(maximumResponseEnvelopeBytes, limits.maximumFrozenBytes))
      artifacts.append([name, SourceDigest(bytes: bytes).rawValue])
    }
    let memory = try MemoryStore(repo: memoryRepository)
    return try DreamRunEncoding.RecoveryCheckpoint(
      schemaVersion: 1, policyVersion: 1,
      sourceBinding: reviewSourceBinding().rawValue,
      repositoryVolume: MemoryReviewEncoding.volumeUUID(at: memoryRepository),
      repositoryInode: UInt64(status.st_ino), runID: sealed.run.runID,
      admissionHash: sealed.admissionHash.rawValue,
      predecessorHash: sealed.admission.predecessorHash,
      frozenProofHash: SourceDigest(bytes: bounded(artifacts)).rawValue,
      decisionsHash: SourceDigest(bytes: bounded(outcome.record)).rawValue,
      candidateIDs: outcome.atomicChanges.map { $0.id.rawValue },
      planHashes: outcome.plans.map {
        SourceDigest(bytes: try bounded(DreamRunEncoding.Plan($0))).rawValue
      },
      confirmedMain: main, snapshotHash: snapshotHash(memory.reviewSnapshot(base: main)))
  }

  private func enrolledRecovery(_ sealed: SealedRun, outcome: Outcome) throws
    -> DreamRunEncoding.RecoveryCheckpoint?
  {
    guard try sealed.directory.isPresent("recovery.json") else { return nil }
    let bytes = try sealed.directory.read("recovery.json", maximum: limits.maximumFrozenBytes)
    let checkpoint = try DreamRunEncoding.decode(
      DreamRunEncoding.RecoveryCheckpoint.self, bytes: bytes)
    guard
      checkpoint
        == (try recoveryCheckpoint(sealed, outcome: outcome, main: checkpoint.confirmedMain)),
      bytes == (try bounded(checkpoint))
    else { throw DreamRunError.corruption }
    return checkpoint
  }

  private func savedRecoveryProof(runID: String) throws -> SavedRecoveryProof {
    guard DreamRunEncoding.isRunID(runID) else { throw DreamRunError.corruption }
    let chain = try loadChain()
    let sealed = try loadAdmission(generation: chain.record.progress.generation, chain: chain)
    guard sealed.run.runID == runID, !(try sealed.directory.isPresent("completion.json")) else {
      throw MemoryError("saved run is not eligible for recovery")
    }
    let outcome = try validatedOutcome(sealed)
    guard !outcome.plans.isEmpty else { throw MemoryError("saved run has no suggestions") }
    let decisions = try bounded(outcome.record)
    guard
      try sealed.directory.read("decisions.json", maximum: limits.maximumFrozenBytes) == decisions
    else {
      throw DreamRunError.corruption
    }
    let receipts = try savedReceipts(sealed, plans: outcome.plans, decisionsBytes: decisions)
    let memory = try MemoryStore(repo: memoryRepository)
    var published: [String] = []
    for plan in outcome.plans {
      let hash = SourceDigest(bytes: try bounded(DreamRunEncoding.Plan(plan))).rawValue
      let existing = try memory.recoverProposal(
        base: plan.base, path: plan.path, replacement: plan.replacement,
        reason: plan.reason, contradictions: plan.contradictions)
      if let receipt = receipts.first(where: { $0.planHash == hash }) {
        guard existing?.commit == receipt.commit else { throw DreamRunError.corruption }
      }
      published.append(existing?.commit ?? "missing")
    }
    let main = try memory.approvedCommit()
    let enrollment = try enrolledRecovery(sealed, outcome: outcome)
    guard main != sealed.run.approvedBase || enrollment != nil else {
      throw MemoryError("saved run can continue normally")
    }
    let checkpoint = try enrollment ?? recoveryCheckpoint(sealed, outcome: outcome, main: main)
    let snapshot = try memory.reviewSnapshot(base: main)
    let frozen = try memory.reviewSnapshot(base: sealed.run.approvedBase)
    let suggestions = try outcome.atomicChanges.map { change -> SavedSuggestionSummary in
      do {
        _ = try MemoryReviewController.recoveredTarget(change, frozen: frozen, snapshot: snapshot)
        return SavedSuggestionSummary(change: change, blocker: nil)
      } catch let error as MemoryError {
        return SavedSuggestionSummary(change: change, blocker: error.description)
      }
    }
    let fingerprint = SourceDigest(
      bytes: try bounded([
        SourceDigest(bytes: bounded(checkpoint)).rawValue, main, snapshotHash(snapshot),
        SourceDigest(bytes: bounded(receipts)).rawValue,
        SourceDigest(bytes: bounded(published)).rawValue,
        SourceDigest(
          bytes: bounded(suggestions.map { [$0.change.id.rawValue, $0.blocker ?? "compatible"] })
        ).rawValue,
      ]))
    return SavedRecoveryProof(
      sealed: sealed, chain: chain, outcome: outcome, main: main, checkpoint: checkpoint,
      fingerprint: fingerprint, suggestions: suggestions)
  }

  package func previewPromptRelocation(
    baselineRunID: String, replacement: URL, sourceRoles: DreamSourceRoles,
    role: DreamRelocationRole = .prompts
  ) throws -> PromptRelocationPreview {
    try withPromptRelocationLock(isConfirming: false, role: role) { _ in
      let comparison = try promptRelocationComparison(
        baselineRunID: baselineRunID, replacement: replacement, roles: sourceRoles, role: role)
      return try PromptRelocationPreview(
        payload: comparison.payload,
        target: comparison.target, mismatches: comparison.mismatches)
    }
  }

  package func confirmPromptRelocation(
    baselineRunID: String, replacement: URL, sourceRoles: DreamSourceRoles,
    expectedPreviewHash: String, authorization: PromptRelocationAuthorization,
    role: DreamRelocationRole = .prompts, decision: DreamRelocationDecision? = nil
  ) throws -> PromptRelocationReceipt {
    try withPromptRelocationLock(isConfirming: true, role: role) { lock in
      _ = try SourceDigest(expectedPreviewHash)
      let comparison = try promptRelocationComparison(
        baselineRunID: baselineRunID, replacement: replacement, roles: sourceRoles, role: role)
      guard comparison.mismatches.isEmpty,
        try comparison.payload.fingerprint.rawValue == expectedPreviewHash
      else { throw MemoryError("prompt relocation preview changed; preview again") }
      var record = PromptRelocationRecord(
        payload: comparison.payload,
        previewHash: expectedPreviewHash, authorization: authorization)
      record.decision = decision
      try persist(
        try record.encoded(), name: role.recordName, directory: root,
        isReplacing: false, isPromptRelocation: true,
        beforeInstall: {
          try self.root.verifyLock(lock)
          guard try self.promptRelocationStoreIdentity() == comparison.payload.store,
            !(try self.root.isPresent(role.recordName))
          else { throw MemoryError("prompt relocation store changed") }
        })
      return PromptRelocationReceipt(
        previewHash: expectedPreviewHash,
        replacement: MemoryStore.safeReviewDisplay(comparison.payload.replacement),
        recordName: role.recordName)
    }
  }

  package func recoverRelocationDecision(role: DreamRelocationRole, decisionID: String) throws -> DreamRelocationDecision? {
    guard operationLock.try() else { throw DreamRunError.busy }
    defer { operationLock.unlock() }
    let lock = try root.openReadLock()
    defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
    guard flock(lock, LOCK_SH | LOCK_NB) == 0 else { throw DreamRunError.busy }
    try root.verifyLock(lock)
    guard try root.isPresent(role.recordName) else { return nil }
    let record = try PromptRelocationRecord.decode(
      root.read(role.recordName, maximum: PromptRelocationRecord.maximumBytes), role: role)
    guard record.payload.store == (try promptRelocationStoreIdentity()) else {
      throw DreamRunError.unsafeState
    }
    return record.decision?.decisionID == decisionID ? record.decision : nil
  }

  private func withPromptRelocationLock<T>(
    isConfirming: Bool, role: DreamRelocationRole, _ body: (Int32) throws -> T
  ) throws -> T {
    guard operationLock.try() else { throw DreamRunError.busy }
    defer { operationLock.unlock() }
    let lock = try root.openReadLock()
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, (isConfirming ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
      throw DreamRunError.busy
    }
    try root.verifyLock(lock)
    _ = try root.retainedBytes(maximum: limits.maximumStateBytes, isDreamAuthority: true)
    _ = try reviewSourceBinding()
    if try root.isPresent(role.recordName) {
      _ = try PromptRelocationRecord.decode(
        root.read(
          role.recordName,
          maximum: PromptRelocationRecord.maximumBytes), role: role)
      throw MemoryError("a prompt relocation record already exists")
    }
    return try body(lock)
  }

  private func promptRelocationStoreIdentity() throws -> PromptRelocationPayload.Store {
    let sourceBinding = try reviewSourceBinding()
    var state = stat()
    var repository = stat()
    guard fstat(root.descriptor, &state) == 0,
      try Self.canonicalExisting(memoryRepository).path == memoryRepository.path,
      lstat(memoryRepository.path, &repository) == 0, repository.st_mode & S_IFMT == S_IFDIR
    else { throw DreamRunError.unsafeState }
    return try .init(
      statePath: reviewStateURL.path,
      stateVolume: MemoryReviewEncoding.volumeUUID(at: reviewStateURL),
      stateInode: UInt64(state.st_ino), sourceBinding: sourceBinding.rawValue,
      rootHash: bindingHash.rawValue, repositoryPath: memoryRepository.path,
      repositoryVolume: MemoryReviewEncoding.volumeUUID(at: memoryRepository),
      repositoryInode: UInt64(repository.st_ino))
  }

  private func promptBaselineProof(
    _ sealed: SealedRun, chain: SuccessfulChain,
    isCompleted: Bool
  ) throws -> PromptRelocationPayload.Baseline {
    let generation = sealed.admission.generation
    var completedHash: String?
    var completionHash: String?
    if isCompleted {
      guard generation < chain.record.progress.generation else { throw DreamRunError.corruption }
      let bytes = try root.child("generations").read(
        "\(generation + 1).json",
        maximum: limits.maximumFrozenBytes)
      let record = try DreamRunEncoding.decode(DreamRunEncoding.Generation.self, bytes: bytes)
      guard chain.hashes[generation + 1] == SourceDigest(bytes: bytes).rawValue,
        record.runID == sealed.run.runID, record.admissionHash == sealed.admissionHash.rawValue
      else { throw DreamRunError.corruption }
      completedHash = SourceDigest(bytes: bytes).rawValue
      completionHash = record.completionHash
    }
    return .init(
      runID: sealed.run.runID, generation: generation,
      admissionHash: sealed.admissionHash.rawValue,
      predecessorHash: sealed.admission.predecessorHash,
      inputHash: sealed.run.inputHash.rawValue, contextHash: sealed.context.contextHash.rawValue,
      requestHash: sealed.request.requestHash.rawValue,
      completedGenerationHash: completedHash, completionHash: completionHash)
  }

  private func promptInventory(
    _ sealed: SealedRun, role: DreamRelocationRole = .prompts,
    isRequiringOriginalBytes: Bool = true
  ) throws -> PromptTemplateInventory {
    guard let provenance = sealed.run.batch.provenance else { throw DreamRunError.corruption }
    let inputs = provenance.stripping.filter { $0.kind == role.inputKind }
    if role == .snippets, isRequiringOriginalBytes {
      guard inputs.allSatisfy({ $0.originalHash == nil || $0.originalHash == SourceDigest(bytes: $0.bytes) }) else {
        throw MemoryError("baseline does not retain exact original snippet bytes")
      }
    }
    return try PromptTemplateInventory(
      inputs: inputs, maximumBytes: limits.maximumFrozenBytes, role: role)
  }

  private func promptRelocationComparison(
    baselineRunID: String, replacement: URL,
    roles: DreamSourceRoles, role: DreamRelocationRole
  ) throws -> (
    payload: PromptRelocationPayload, target: PromptTemplateInventory, mismatches: [String]
  ) {
    guard DreamRunEncoding.isRunID(baselineRunID), role.isPresent(roles) else {
      throw MemoryError("prompt relocation requires a named baseline and registered prompts")
    }
    _ = try roles.sources(configuredRoots)
    var selected: SealedRun?
    var encountered: [PromptRelocationPayload.Coverage.OtherInventory] = []
    let chain = try loadChain(capture: { sealed, _, _ in
      let inventory = try self.promptInventory(sealed, role: role, isRequiringOriginalBytes: false)
      encountered.append(.init(runID: sealed.run.runID, templateDigest: inventory.digest))
      if sealed.run.runID == baselineRunID { selected = sealed }
    })
    let head = chain.record.progress.generation
    var current: SealedRun?
    if try root.child("admissions").isPresent("\(head).json") {
      current = try loadAdmission(generation: head, chain: chain)
      if current?.run.runID == baselineRunID { selected = current }
      if let current {
        encountered.append(
          .init(
            runID: current.run.runID,
            templateDigest: try promptInventory(current, role: role, isRequiringOriginalBytes: false).digest))
      }
    }
    guard let selected else { throw MemoryError("baseline is not an authoritative admitted input") }
    let inventory = try promptInventory(selected, role: role)
    guard inventory.entryCount > 0 else {
      throw MemoryError("baseline has no complete prompt inventory")
    }
    let binding = try DreamRunEncoding.decode(RootBinding.self, bytes: bindingBytes)
    let offset = role.offset(roles)
    let canonical = binding.stripping[offset]
    let original = (binding.originalRoots.map { Array($0.dropFirst(2)) } ?? binding.stripping)[offset]
    try Self.requireMissingSource(original: original, canonical: canonical)
    try validatePromptReplacement(replacement)
    let captured = try PreparationDirectory(url: replacement).checkedTemplates(
      maximumBytes: limits.maximumFrozenBytes, role: role)
    let target = try PromptTemplateInventory(
      inputs: captured, maximumBytes: limits.maximumFrozenBytes, role: role)
    let baselineInputs = selected.run.batch.provenance!.stripping.filter { $0.kind == role.inputKind }
    var mismatches: [String] = []
    let oldNames = Set(baselineInputs.map { Data($0.name.utf8) })
    let newNames = Set(captured.map { Data($0.name.utf8) })
    let targetBytes = Dictionary(
      uniqueKeysWithValues: captured.map { (Data($0.name.utf8), $0.bytes) })
    for input in baselineInputs {
      if !newNames.contains(Data(input.name.utf8)) {
        mismatches.append("missing template: \(input.name)")
      } else if input.bytes != targetBytes[Data(input.name.utf8)] {
        mismatches.append("changed template bytes: \(input.name)")
      }
    }
    for input in captured where !oldNames.contains(Data(input.name.utf8)) {
      mismatches.append("extra template: \(input.name)")
    }
    let isCompleted = selected.admission.generation < head
    let payload = try PromptRelocationPayload(
      schemaVersion: 1, policyVersion: 1,
      kind: role.recordKind, store: promptRelocationStoreIdentity(), role: role.rawValue,
      roles: roles, strippingOffset: offset, registeredOriginal: original,
      registeredCanonical: canonical, replacement: replacement.path,
      baseline: promptBaselineProof(selected, chain: chain, isCompleted: isCompleted),
      anchor: .init(
        generation: head, generationHash: chain.hash.rawValue,
        currentAdmissionHash: current?.admissionHash.rawValue),
      inventory: inventory,
      coverage: .init(
        claim: role == .prompts ? "complete-template-subset-of-selected-input-only" : "complete-raw-snippet-subset-of-selected-input-only",
        isCompleted: isCompleted,
        isNewerCompletedCapturePresent: selected.admission.generation < head
          && head - selected.admission.generation > 1,
        differingInventories: encountered.filter { $0.templateDigest != inventory.digest },
        limitations: [
          role == .prompts ? "Equality covers only the selected frozen input's complete template subset." : "Equality covers only the selected frozen input's complete raw snippet subset.",
          "Other versions and outstanding expansions are not universally proven equivalent.",
        ] + (role == .snippets ? [
          "Other capture digests describe retained admitted bytes; original raw snippet equivalence is unproven."
        ] : [])),
      isRecordAbsent: true)
    _ = try PromptRelocationRecord(
      payload: payload, previewHash: payload.fingerprint.rawValue,
      authorization: .explicitCaller
    ).encoded()
    return (payload, target, mismatches)
  }

  private static func requireMissingSource(original: String, canonical: String) throws {
    for path in Set([original, canonical]) {
      var status = stat()
      guard lstat(path, &status) != 0, errno == ENOENT else {
        throw MemoryError("registered prompt source is present or unsafe")
      }
      if let resolved = realpath(path, nil) {
        free(resolved)
        throw MemoryError("registered prompt source is not missing")
      }
      guard errno == ENOENT else { throw DreamRunError.unsafeState }
    }
    var ancestor = URL(fileURLWithPath: original)
    var suffix: [String] = []
    var status = stat()
    while lstat(ancestor.path, &status) != 0 {
      guard errno == ENOENT, ancestor.path != "/" else { throw DreamRunError.unsafeState }
      suffix.insert(ancestor.lastPathComponent, at: 0)
      ancestor.deleteLastPathComponent()
    }
    let resolved = try canonicalExisting(ancestor)
    let expected = suffix.reduce(resolved) { $0.appendingPathComponent($1) }
    guard Data(expected.path.utf8) == Data(canonical.utf8) else { throw DreamRunError.unsafeState }
  }

  private func validatePromptReplacement(_ replacement: URL) throws {
    guard replacement.isFileURL, replacement.path.hasPrefix("/"),
      replacement.path.utf8.count <= 4096, !replacement.path.contains("\0"),
      !replacement.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      Data(try Self.canonicalExisting(replacement).path.utf8) == Data(replacement.path.utf8)
    else { throw MemoryError("replacement prompts require an exact canonical directory") }
    for source in configuredRoots + [reviewStateURL] {
      guard !Self.isWithin(replacement, source), !Self.isWithin(source, replacement) else {
        throw MemoryError("replacement prompts overlap a registered source or dream state")
      }
    }
    try PreparationDirectory(url: replacement).verifyPromptRoot()
  }

  private func freshSources(roles: DreamSourceRoles, chain: SuccessfulChain) throws
    -> DreamFreshSources
  {
    _ = try roles.sources(configuredRoots)
    var replacements: [Int: URL] = [:]
    for role in DreamRelocationRole.allCases where try root.isPresent(role.recordName) {
      let replacement = try validatedRelocation(role: role, roles: roles, chain: chain)
      replacements[2 + role.offset(roles)] = replacement
    }
    return try roles.sources(configuredRoots.indices.map { index in
      let source = try replacements[index] ?? acceptedCanonicalRoot(at: index)
      _ = try PreparationDirectory(url: source)
      return source
    })
  }

  private func validatedRelocation(
    role: DreamRelocationRole, roles: DreamSourceRoles, chain: SuccessfulChain
  ) throws -> URL {
    let record = try PromptRelocationRecord.decode(
      root.read(role.recordName, maximum: PromptRelocationRecord.maximumBytes), role: role)
    let payload = record.payload
    let binding = try DreamRunEncoding.decode(RootBinding.self, bytes: bindingBytes)
    let offset = role.offset(roles)
    guard role.isPresent(roles), payload.roles == roles,
      payload.strippingOffset == offset,
      payload.store == (try promptRelocationStoreIdentity()),
      Data(payload.registeredCanonical.utf8) == Data(binding.stripping[offset].utf8),
      Data(payload.registeredOriginal.utf8)
        == Data(
          (binding.originalRoots.map { Array($0.dropFirst(2)) }
            ?? binding.stripping)[offset].utf8),
      chain.hashes[payload.anchor.generation] == payload.anchor.generationHash
    else { throw MemoryError("prompt relocation does not belong to this store and role") }
    if let admissionHash = payload.anchor.currentAdmissionHash {
      let anchor = try loadAdmission(generation: payload.anchor.generation, chain: chain)
      guard anchor.admissionHash.rawValue == admissionHash else { throw DreamRunError.corruption }
    }
    let baseline = try loadAdmission(generation: payload.baseline.generation, chain: chain)
    guard
      payload.baseline
        == (try promptBaselineProof(
          baseline, chain: chain,
          isCompleted: payload.baseline.completedGenerationHash != nil)),
      payload.inventory == (try promptInventory(baseline, role: role)),
      payload.baseline.generation <= payload.anchor.generation
    else { throw MemoryError("prompt relocation baseline authority changed") }
    try Self.requireMissingSource(
      original: payload.registeredOriginal, canonical: payload.registeredCanonical)
    let replacement = URL(fileURLWithPath: payload.replacement)
    try validatePromptReplacement(replacement)
    if role == .snippets {
      let captured = try PreparationDirectory(url: replacement).checkedTemplates(
        maximumBytes: limits.maximumFrozenBytes, role: role)
      guard try PromptTemplateInventory(inputs: captured, maximumBytes: limits.maximumFrozenBytes, role: role) == payload.inventory else {
        throw MemoryError("relocated snippet inventory changed")
      }
    }
    return replacement
  }

  package func inspectQueue(
    isSnippetsPresent: Bool, isPromptsPresent: Bool, date: Date = Date()
  ) throws -> DreamQueueCoverage {
    guard operationLock.try() else { throw DreamRunError.busy }
    defer { operationLock.unlock() }
    let lock = try root.openReadLock()
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, LOCK_SH | LOCK_NB) == 0 else { throw DreamRunError.busy }
    try root.verifyLock(lock)
    _ = try root.retainedBytes(maximum: limits.maximumStateBytes, isDreamAuthority: true)
    _ = try reviewSourceBinding()
    let chain = try loadChain()
    let progress = try chain.record.progress.domain()
    let roles = DreamSourceRoles(
      isSnippetsPresent: isSnippetsPresent, isPromptsPresent: isPromptsPresent)
    let sources: DreamFreshSources
    do {
      sources = try freshSources(roles: roles, chain: chain)
    } catch DreamRunError.unsafeState {
      if !(try root.isPresent(PromptRelocationRecord.name)) {
        let historical = try roles.sources(configuredRoots)
        if let prompts = historical.prompts,
          (try? Self.requireMissingSource(original: prompts.path, canonical: prompts.path)) != nil
        {
          throw MemoryError("no prompt templates in --prompts")
        }
        if let snippets = historical.snippets,
          (try? Self.requireMissingSource(original: snippets.path, canonical: snippets.path)) != nil
        {
          throw MemoryError("no snippet bodies in --snippets")
        }
      }
      throw DreamRunError.unsafeState
    }
    var backlog: DreamBacklog?
    let batch = try SessionReader(
      sessions: sources.sessions, snippets: sources.snippets, prompts: sources.prompts
    ).prepare(
      progress: progress, limits: DreamInputLimits(),
      modifiedAfter: date.addingTimeInterval(-SessionReader.dreamWindow),
      backlog: { backlog = $0 }, isCancelled: { Task.isCancelled })
    guard let backlog else { throw DreamRunError.missingPayload }
    return try DreamQueueCoverage(
      backlogBytes: backlog.backlogBytes, backlogLimitBytes: SessionReader.dreamBacklogBytes,
      undreamtBytes: backlog.undreamtBytes, nextBytes: backlog.nextBytes,
      plannedBytes: UInt64(batch.keptBytes), completedBytes: 0)
  }

  public func run(
    selection: DreamSelectedCall, resume: DreamResumeAction = .inspectOrContinue,
    prepare: (DreamProgress) throws -> PreparedSessionBatch,
    call: (DreamModelRequest) throws -> DreamCompletedResponse,
    observe: (DreamProgress, PreparedSessionBatch, Bool, Double?) throws -> Void = { _, _, _, _ in }
  ) throws -> DreamTransactionResult {
    try performRun(
      selection: selection, resume: resume, sourceRoles: nil, excludedSessionIDs: [],
      prepare: { progress, _ in try prepare(progress) }, protect: nil, remainingProtections: nil,
      call: call, observe: observe)
  }

  package func run(
    selection: DreamSelectedCall, resume: DreamResumeAction = .inspectOrContinue,
    sourceRoles: DreamSourceRoles, excludedSessionIDs: Set<String> = [],
    protect: @escaping ([String]) throws -> Void,
    remainingProtections: (() -> Int)? = nil,
    prepare: (DreamProgress, DreamFreshSources) throws -> PreparedSessionBatch,
    call: (DreamModelRequest) throws -> DreamCompletedResponse,
    observe: (DreamProgress, PreparedSessionBatch, Bool, Double?) throws -> Void = { _, _, _, _ in }
  ) throws -> DreamTransactionResult {
    try performRun(
      selection: selection, resume: resume, sourceRoles: sourceRoles,
      excludedSessionIDs: excludedSessionIDs,
      prepare: { progress, sources in
        guard let sources else { throw DreamRunError.unsafeState }
        return try prepare(progress, sources)
      }, protect: protect, remainingProtections: remainingProtections, call: call,
      observe: observe)
  }

  private func performRun(
    selection: DreamSelectedCall, resume: DreamResumeAction, sourceRoles: DreamSourceRoles?,
    excludedSessionIDs: Set<String>,
    prepare: (DreamProgress, DreamFreshSources?) throws -> PreparedSessionBatch,
    protect: (([String]) throws -> Void)?, remainingProtections: (() -> Int)?,
    call: (DreamModelRequest) throws -> DreamCompletedResponse,
    observe: (DreamProgress, PreparedSessionBatch, Bool, Double?) throws -> Void
  ) throws -> DreamTransactionResult {
    guard operationLock.try() else { throw DreamRunError.busy }
    defer { operationLock.unlock() }
    let ownership = try root.openLock()
    let lock = ownership.descriptor
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      _ = close(lock)
      if code == EWOULDBLOCK { throw DreamRunError.busy }
      throw DreamRunError.persistenceFailure
    }
    var isLockClosed = false
    defer {
      if !isLockClosed {
        _ = flock(lock, LOCK_UN)
        _ = close(lock)
      }
    }
    try root.verifyLock(lock)
    var measuredSeconds: Double?
    var observedRecordCount = 0
    var observedInputBytes = 0
    let result = try runLocked(
      selection: selection, resume: resume, isLockCreated: ownership.isCreated,
      sourceRoles: sourceRoles, excludedSessionIDs: excludedSessionIDs,
      prepare: prepare, protect: protect, remainingProtections: remainingProtections,
      call: { request in
        let started = ContinuousClock.now
        let response = try call(request)
        let elapsed = started.duration(to: .now).components
        measuredSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return response
      },
      observe: { progress, batch, isRepeated in
        observedRecordCount = batch.exactSourceRecords.count
        observedInputBytes = batch.keptBytes
        var estimate: Double?
        if (try? self.root.isPresent("timing.json")) == true,
          let timingBytes = try? self.root.read(
            "timing.json", maximum: DreamRunEncoding.maximumMetadataBytes),
          let timing = try? DreamRunEncoding.decode(DreamTiming.self, bytes: timingBytes)
        {
          if timing.provider == selection.provider, timing.modelID == selection.modelID,
            timing.thinkingLevel == selection.thinkingLevel,
            timing.records == observedRecordCount, timing.inputBytes == observedInputBytes,
            timing.seconds.isFinite, timing.seconds > 0
          {
            estimate = timing.seconds
          }
        }
        try observe(progress, batch, isRepeated, estimate)
      })
    if case .completed = result, let measuredSeconds, measuredSeconds > 0 {
      try? persist(
        bounded(
          DreamTiming(
            provider: selection.provider, modelID: selection.modelID,
            thinkingLevel: selection.thinkingLevel, records: observedRecordCount,
            inputBytes: observedInputBytes, seconds: measuredSeconds)),
        name: "timing.json", directory: root, isReplacing: true)
    }
    guard flock(lock, LOCK_UN) == 0 else { throw DreamRunError.persistenceFailure }
    guard close(lock) == 0 else { throw DreamRunError.persistenceFailure }
    isLockClosed = true
    return result
  }

  private func runLocked(
    selection: DreamSelectedCall, resume: DreamResumeAction, isLockCreated: Bool,
    sourceRoles: DreamSourceRoles?, excludedSessionIDs: Set<String>,
    prepare: (DreamProgress, DreamFreshSources?) throws -> PreparedSessionBatch,
    protect: (([String]) throws -> Void)?, remainingProtections: (() -> Int)?,
    call: (DreamModelRequest) throws -> DreamCompletedResponse,
    observe: (DreamProgress, PreparedSessionBatch, Bool) throws -> Void
  ) throws -> DreamTransactionResult {
    _ = try root.retainedBytes(maximum: limits.maximumStateBytes, isDreamAuthority: true)
    if try root.names(isDreamAuthority: true) == ["writer.lock"] {
      guard isLockCreated else { throw DreamRunError.missingPayload }
      try persist(bindingBytes, name: "root.json", directory: root, isReplacing: false)
      for name in ["runs", "admissions", "generations"] {
        _ = try root.child(name, isCreating: true)
        try synchronize(root, name: name)
      }
      let genesis = DreamRunEncoding.Generation(
        schemaVersion: 2, bindingHash: bindingHash.rawValue, predecessorHash: nil,
        admissionHash: nil, completionHash: nil, runID: nil,
        progress: DreamRunEncoding.Progress(try DreamProgress()))
      try install(genesis, name: "0.json", directory: root.child("generations"))
      try save(generation: 0, hash: SourceDigest(bytes: DreamRunEncoding.encode(genesis)))
    } else {
      let bytes = try root.read("root.json", maximum: DreamRunEncoding.maximumMetadataBytes)
      _ = try DreamRunEncoding.decode(RootBinding.self, bytes: bytes)
      guard bytes == bindingBytes else { throw DreamRunError.unsafeState }
    }
    var admittedViews: [String: DreamAdmittedView] = [:]
    var retainedBatches: [PreparedSessionBatch] = []
    let chain = try loadChain(capture: { sealed, _, _ in
      for view in sealed.run.batch.admittedViews {
        if let prior = admittedViews[view.path] { try view.requireExtension(of: prior) }
        admittedViews[view.path] = view
      }
      retainedBatches.append(sealed.run.batch)
      if retainedBatches.count > 7 { retainedBatches.removeFirst() }
    })
    let progress = try chain.record.progress.domain()
    let admissions = try root.child("admissions")
    let runs = try root.child("runs")
    var isRecovered = false
    var cached: DreamRunEncoding.State?
    if try root.isPresent("state.json") {
      cached = try DreamRunEncoding.decode(
        DreamRunEncoding.State.self,
        bytes: root.read("state.json", maximum: DreamRunEncoding.maximumMetadataBytes))
      guard let cached, cached.generation <= progress.generation,
        chain.hashes[cached.generation] == cached.generationHash,
        (cached.runID == nil) == (cached.admissionHash == nil)
      else { throw DreamRunError.corruption }
      if let runID = cached.runID, let hash = cached.admissionHash {
        let admissionBytes = try admissions.read(
          "\(cached.generation).json", maximum: DreamRunEncoding.maximumMetadataBytes)
        let admission = try DreamRunEncoding.decode(
          DreamRunEncoding.Admission.self, bytes: admissionBytes)
        guard admission.runID == runID, SourceDigest(bytes: admissionBytes).rawValue == hash else {
          throw DreamRunError.corruption
        }
      }
    }
    for name in try admissions.names() where !name.hasPrefix(".pending-") {
      guard name.hasSuffix(".json"), let generation = UInt64(name.dropLast(5)),
        name == "\(generation).json", generation <= progress.generation
      else { throw DreamRunError.corruption }
    }
    if resume == .replaceInvalidResponse,
      !(try admissions.isPresent("\(progress.generation).json"))
    {
      throw DreamRunError.replacementUnavailable
    }
    if progress.generation > 0,
      !(try admissions.isPresent("\(progress.generation).json")),
      cached == nil || cached!.generation < progress.generation || resume == .retryInterruptedCall
    {
      guard let runID = chain.record.runID else { throw DreamRunError.corruption }
      let prior = try loadAdmission(generation: progress.generation - 1, chain: chain)
      guard prior.run.runID == runID else { throw DreamRunError.corruption }
      try checkProtection(prior, excludedSessionIDs: excludedSessionIDs, protect: protect)
      try observe(prior.run.progress, prior.run.batch, false)
      return try finish(
        prior, chain: chain, isRecovered: true, isCommitted: true)
    }
    let sealed: SealedRun
    if try admissions.isPresent("\(progress.generation).json") {
      sealed = try loadAdmission(generation: progress.generation, chain: chain)
      isRecovered = true
    } else {
      guard cached?.runID == nil else { throw DreamRunError.missingPayload }
      var sources: DreamFreshSources?
      if let sourceRoles {
        sources = try freshSources(roles: sourceRoles, chain: chain)
        sources?.admittedViews = admittedViews.values.sorted { $0.path < $1.path }
      } else {
        guard !(try root.isPresent(PromptRelocationRecord.name)) else {
          throw MemoryError("fresh prompt relocation requires named source roles")
        }
        for index in configuredRoots.indices {
          _ = try PreparationDirectory(url: acceptedCanonicalRoot(at: index))
        }
        sources = nil
      }
      let batch = try prepare(progress, sources)
      try batch.requireNoExcludedSessions(excludedSessionIDs)
      for view in batch.admittedViews {
        if let prior = admittedViews[view.path] { try view.requireExtension(of: prior) }
      }
      do {
        try DreamRunEncoding.validate(progress: progress, batch: batch, limits: limits)
      } catch let error as DreamRunError { throw error } catch { throw DreamRunError.corruption }
      if batch.exactSourceRecords.isEmpty {
        try observe(progress, batch, false)
        if cached == nil { try save(generation: progress.generation, hash: chain.hash) }
        return .noNewRecords(
          generation: progress.generation, unfinishedTails: batch.unfinishedTails)
      }
      if let protect { try protect(DreamSourceProtection.pieces(batch)) }
      guard progress.generation < UInt64.max else { throw DreamRunError.staleGeneration }
      let memory = try MemoryStore(repo: memoryRepository)
      let base = try memory.approvedCommit()
      let runID = UUID().uuidString.lowercased()
      let input = try DreamRunEncoding.input(
        runID: runID, context: DreamRunContext(selection: selection, currentApprovedBase: base),
        bindingHash: bindingHash, progress: progress, batch: batch, limits: limits,
        predecessorProgressHash: chain.hash)
      let run = try DreamRunEncoding.frozen(
        bytes: input, runID: runID, inputHash: SourceDigest(bytes: input),
        bindingHash: bindingHash, limits: limits)
      let date = clock()
      let context = try capture(
        run: run, memory: memory, date: date, retainedBatches: retainedBatches,
        excludedSessionIDs: excludedSessionIDs, protect: protect,
        remainingProtections: remainingProtections)
      let milliseconds = date.timeIntervalSince1970 * 1_000
      guard milliseconds.isFinite, milliseconds >= Double(Int64.min),
        milliseconds < Double(Int64.max)
      else { throw DreamRunError.corruption }
      let request = DreamRunEncoding.Request(
        schemaVersion: 3, runID: runID, generation: progress.generation,
        inputHash: run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
        systemPrompt: context.savedSystemPrompt,
        messages: try context.requestMessages(timestampMilliseconds: Int64(milliseconds)),
        renderingVersion: DreamRequestRendering.connectedV3.rawValue)
      let requestBytes = try bounded(request)
      let directory = try runs.child(runID, isCreating: true)
      try synchronize(runs, name: "runDirectory")
      _ = try directory.child("receipts", isCreating: true)
      try synchronize(directory, name: "receipts")
      try persist(input, name: "input.json", directory: directory, isReplacing: false)
      try persist(
        context.canonicalBytes, name: "context.json", directory: directory, isReplacing: false)
      try persist(requestBytes, name: "request.json", directory: directory, isReplacing: false)
      let admission = DreamRunEncoding.Admission(
        schemaVersion: 2, bindingHash: bindingHash.rawValue, generation: progress.generation,
        predecessorHash: chain.hash.rawValue, runID: runID, inputHash: run.inputHash.rawValue,
        contextHash: context.contextHash.rawValue,
        requestHash: SourceDigest(bytes: requestBytes).rawValue,
        selection: DreamRunEncoding.Selection(selection), base: base)
      let admissionBytes = try bounded(admission)
      try persist(
        admissionBytes, name: "\(progress.generation).json", directory: admissions,
        isReplacing: false)
      sealed = SealedRun(
        admission: admission, admissionHash: SourceDigest(bytes: admissionBytes), run: run,
        context: context,
        request: try request.domain(run: run, context: context, bytes: requestBytes),
        rendering: .connectedV3, directory: directory)
      try save(generation: progress.generation, hash: chain.hash, sealed: sealed)
    }
    guard sealed.rendering != .scopeV2 else { throw DreamRunError.unsupportedSchema }
    if isRecovered {
      try checkProtection(sealed, excludedSessionIDs: excludedSessionIDs, protect: protect)
    }
    var attempt: ResponseAttempt
    do {
      let verified = try attemptReader(sealed).verify()
      guard verified.replacement?.schemaVersion != 3 || verified.response != nil else {
        throw DreamRunError.unsupportedSchema
      }
      attempt = verified.attempt
    }
    if isRecovered, cached?.admissionHash != sealed.admissionHash.rawValue {
      try save(generation: sealed.run.progress.generation, hash: chain.hash, sealed: sealed)
    }
    var isReplacementStarted = false
    if resume == .replaceInvalidResponse, try sealed.directory.isPresent(attempt.responseName) {
      guard !(try sealed.directory.isPresent("decisions.json")),
        !(try sealed.directory.isPresent("completion.json")),
        try sealed.directory.child("receipts").names().isEmpty
      else { throw DreamRunError.replacementUnavailable }
      do {
        _ = try validatedOutcome(sealed, attempt: attempt)
        throw DreamRunError.replacementUnavailable
      } catch is DreamDecisionError {
        if isCancelled() { return pending(sealed, reason: .cancelled) }
        guard attempt.number < ResponseAttempt.maximumReplacements else {
          throw DreamRunError.limitExceeded
        }
        let next = ResponseAttempt(number: attempt.number + 1)
        let rejected = try sealed.directory.read(
          attempt.responseName, maximum: maximumResponseEnvelopeBytes)
        try persist(
          rejected, name: next.archiveName, directory: sealed.directory, isReplacing: false)
        try install(
          DreamRunEncoding.ReplacementIntent(
            schemaVersion: 2, admissionHash: sealed.admissionHash.rawValue,
            requestHash: sealed.request.requestHash.rawValue,
            rejectedResponseHash: SourceDigest(bytes: rejected).rawValue),
          name: next.intentName, directory: sealed.directory)
        attempt = next
        isReplacementStarted = true
      }
    } else if resume == .replaceInvalidResponse, attempt.number == 0 {
      throw DreamRunError.replacementUnavailable
    }
    try observe(
      sealed.run.progress, sealed.run.batch,
      (attempt.number > 0 || (try sealed.directory.isPresent(attempt.callName)))
        && !(try sealed.directory.isPresent(attempt.responseName)))
    if !sealed.run.batch.evidence.isEmpty,
      !(try sealed.directory.isPresent(attempt.responseName))
    {
      guard !(try sealed.directory.isPresent("decisions.json")),
        !(try sealed.directory.isPresent("completion.json"))
      else { throw DreamRunError.missingPayload }
      if isCancelled() { return pending(sealed, reason: .cancelled) }
      if try sealed.directory.isPresent(attempt.callName) {
        let callSelection = try loadCallSelection(sealed, attempt: attempt)
        if resume == .retryInterruptedCall ? callSelection != selection : !isReplacementStarted {
          return pending(sealed, reason: .interruptedCall, callSelection: callSelection)
        }
      } else if attempt.number > 0, !isReplacementStarted, resume != .retryInterruptedCall {
        return pending(sealed, reason: .interruptedCall)
      }
      if attempt.number > 0 {
        for name in [attempt.archiveName, attempt.intentName] {
          let bytes = try sealed.directory.read(name, maximum: maximumResponseEnvelopeBytes)
          try persist(bytes, name: name, directory: sealed.directory, isReplacing: false)
        }
      }
      let intent = DreamRunEncoding.Intent(
        schemaVersion: 2, admissionHash: sealed.admissionHash.rawValue,
        requestHash: sealed.request.requestHash.rawValue,
        selection: selection == sealed.run.selection ? nil : DreamRunEncoding.Selection(selection))
      try persist(
        bounded(intent), name: attempt.callName, directory: sealed.directory, isReplacing: true)
      let request = DreamModelRequest(
        runID: sealed.request.runID, generation: sealed.request.generation,
        inputHash: sealed.request.inputHash, contextHash: sealed.request.contextHash,
        requestHash: sealed.request.requestHash, selection: selection,
        systemPrompt: sealed.request.systemPrompt, messages: sealed.request.messages)
      let response: DreamCompletedResponse
      do { response = try call(request) } catch is CancellationError {
        return pending(sealed, reason: .cancelled)
      } catch { return pending(sealed, reason: .callbackFailure) }
      if isCancelled() { return pending(sealed, reason: .cancelled) }
      guard response.text.utf8.count <= limits.maximumResponseBytes else {
        throw DreamRunError.limitExceeded
      }
      let envelope = DreamRunEncoding.BoundResponse(
        schemaVersion: 2, admissionHash: sealed.admissionHash.rawValue,
        runID: sealed.run.runID, generation: sealed.run.progress.generation,
        inputHash: sealed.run.inputHash.rawValue, contextHash: sealed.context.contextHash.rawValue,
        requestHash: sealed.request.requestHash.rawValue,
        selection: DreamRunEncoding.Selection(selection), text: response.text)
      try install(envelope, name: attempt.responseName, directory: sealed.directory)
    }
    return try finish(sealed, chain: chain, isRecovered: isRecovered, isCommitted: false)
  }

  private func checkProtection(
    _ sealed: SealedRun, excludedSessionIDs: Set<String>, protect: (([String]) throws -> Void)?
  ) throws {
    try sealed.run.batch.requireNoExcludedSessions(excludedSessionIDs)
    let related = try (sealed.context.connectedEvidence?.relatedBatchBytes ?? []).map {
      try DreamRunEncoding.retainedBatch(bytes: $0)
    }
    for batch in related { try batch.requireNoExcludedSessions(excludedSessionIDs) }
    guard
      sealed.context.rejectedPredecessors.allSatisfy({
        excludedSessionIDs.isDisjoint(with: $0.sourceSessions)
      })
    else { throw MemoryError("live session excluded from dream intake") }
    guard let protect else { return }
    try protect(DreamSourceProtection.pieces(sealed.run.batch))
    for batch in related {
      guard batch.evidence.allSatisfy({ $0.originalWitness != nil }),
        !batch.admittedViews.isEmpty
      else { throw MemoryError("retained dream context lacks an admitted source view") }
      try protect(DreamSourceProtection.pieces(batch))
    }
    if !sealed.context.rejectedPredecessors.isEmpty {
      try protect(DreamSourceProtection.rejectedPredecessors(sealed.context.rejectedPredecessors))
    }
    try protect(
      DreamSourceProtection.authority(sealed.context.snapshot, owners: sealed.context.owners))
    try protect([sealed.request.systemPrompt] + sealed.request.messages.map(\.text))
  }

  private func capture(
    run: FrozenDreamRun, memory: MemoryStore, date: Date,
    retainedBatches: [PreparedSessionBatch], excludedSessionIDs: Set<String>,
    protect: (([String]) throws -> Void)?, remainingProtections: (() -> Int)?
  ) throws
    -> DreamDecisionContext
  {
    let decisionLimits = try DreamDecisionLimits(
      maximumResponseBytes: limits.maximumResponseBytes,
      maximumFrozenBytes: limits.maximumFrozenBytes)
    var limitations: [String] = []
    var relatedBatches = try selectRetainedBatches(
      current: run.batch, retained: retainedBatches, excludedSessionIDs: excludedSessionIDs,
      limitations: &limitations)
    if let remainingProtections {
      let protectionsAfterRelated = 3
      let suppliedCount = max(0, remainingProtections() - protectionsAfterRelated)
      if relatedBatches.count > suppliedCount {
        relatedBatches = Array(relatedBatches.prefix(suppliedCount))
        limitations.append(
          "A related retained window exceeded the source-check limit and was not supplied.")
      }
    }
    let catalogue =
      try relatedBatches.isEmpty
      ? run.batch.evidence
      : ConnectedDreamEvidence(current: run.batch, relatedBatches: relatedBatches).evidence
    if let protect {
      for batch in relatedBatches { try protect(DreamSourceProtection.pieces(batch)) }
    }
    var resolutions: [Data: PinnedScopeResolution] = [:]
    var projectRoots: [String: (root: URL, key: String)] = [:]
    var scopes: [PinnedEvidenceScope] = []
    for evidence in catalogue {
      let lookup = Data((evidence.projectScope ?? "").utf8)
      let resolution: PinnedScopeResolution
      if let saved = resolutions[lookup] {
        resolution = saved
      } else {
        do {
          guard let cwd = evidence.projectScope, cwd.hasPrefix("/"), !cwd.contains("\0") else {
            throw DreamRunError.unsafeState
          }
          let source = try Self.canonicalExisting(URL(fileURLWithPath: cwd))
          _ = try PreparationDirectory(url: source)
          let git = Git(repo: source, environment: ProcessInfo.processInfo.environment)
          if let key = try MemoryStore.projectKey(cwd: source, projectBindings: projectBindings) {
            let worktree = try Self.canonicalExisting(
              URL(fileURLWithPath: git.text(["rev-parse", "--show-toplevel"])))
            resolution = .project(key: key, isGlobalEligible: true)
            projectRoots[worktree.path] = (worktree, key)
          } else {
            resolution = .outsideGit(isGlobalEligible: true)
          }
        } catch {
          resolution = .unresolved
          limitations.append(
            "A source working directory could not be resolved; its scope is unresolved.")
        }
        resolutions[lookup] = resolution
      }
      scopes.append(
        PinnedEvidenceScope(
          source: evidence.id, projectScope: evidence.projectScope, resolution: resolution))
    }
    let keys = Set(
      scopes.compactMap { scope -> String? in
        if case .project(let key, _) = scope.resolution { return key }
        return nil
      }
    ).sorted()
    let snapshot = try memory.decisionSnapshot(
      base: run.approvedBase, projectKeys: keys, limits: decisionLimits, deviceKey: deviceKey)
    if let protect { try protect(DreamSourceProtection.authority(snapshot, owners: [])) }
    var owners: [PinnedOwnerInput] = []
    var attempted: Set<Data> = []
    var totalBytes = 0
    func captureOwner(_ file: URL, scope: DreamMemoryScope) throws -> String? {
      guard !DreamSourceProtection.isProtectedPath(file.path) else {
        throw DreamSourceProtectionError.blocked
      }
      guard attempted.insert(Data(file.path.utf8)).inserted else { return nil }
      let parent: URL
      do { parent = try Self.canonicalExisting(file.deletingLastPathComponent()) } catch {
        limitations.append(
          "A grounded local instruction-owner file is missing; owner coverage is incomplete.")
        return nil
      }
      let canonical = parent.appendingPathComponent(file.lastPathComponent)
      if Data(canonical.path.utf8) != Data(file.path.utf8) {
        guard attempted.insert(Data(canonical.path.utf8)).inserted else { return nil }
      }
      let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard directory >= 0 else { throw DreamRunError.unsafeState }
      defer { _ = close(directory) }
      var status = stat()
      if fstatat(directory, file.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) != 0 {
        guard errno == ENOENT else { throw DreamRunError.unsafeState }
        limitations.append(
          "A grounded local instruction-owner file is missing; owner coverage is incomplete.")
        return nil
      }
      guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
        throw DreamRunError.unsafeState
      }
      try decisionLimits.check(owners.count + 1, maximum: decisionLimits.maximumOwners)
      guard UInt64(status.st_size) <= UInt64(decisionLimits.maximumSingleOwnerBytes) else {
        throw DreamRunError.limitExceeded
      }
      let count = Int(status.st_size)
      try decisionLimits.accumulate(
        count, total: &totalBytes, maximum: decisionLimits.maximumOwnerBytes)
      let descriptor = openat(
        directory, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { throw DreamRunError.unsafeState }
      defer { _ = close(descriptor) }
      var opened = stat()
      guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
        opened.st_dev == status.st_dev, opened.st_ino == status.st_ino,
        opened.st_size == status.st_size
      else { throw DreamRunError.unsafeState }
      var bytes = Data(count: count)
      try bytes.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < count {
          let read = Darwin.read(descriptor, buffer.baseAddress! + offset, count - offset)
          if read < 0, errno == EINTR { continue }
          guard read > 0 else { throw DreamRunError.corruption }
          offset += read
        }
      }
      var extra: UInt8 = 0
      guard Darwin.read(descriptor, &extra, 1) == 0 else { throw DreamRunError.corruption }
      guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
        throw DreamRunError.unsafeState
      }
      let key = SourceDigest(bytes: Data(canonical.path.utf8)).rawValue
      let reference = canonical.lastPathComponent + " (" + key + ")"
      owners.append(
        try PinnedOwnerInput(key: key, reference: reference, scope: scope, bytes: bytes))
      return text
    }
    func locators(_ text: String, directory: URL, scope: DreamMemoryScope) throws {
      let expression = try NSRegularExpression(
        pattern:
          #"\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|"([^"\n]+)"|'([^'\n]+)'|([^\)\n]+))\s*\)|"([^"\n]+)"|'([^'\n]+)'|`([^`\n]+)`|[^\s<>"'`]+"#
      )
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      for match in expression.matches(in: text, range: range) {
        guard let matchRange = Range(match.range, in: text) else { throw DreamRunError.corruption }
        let captured = (1..<match.numberOfRanges).first {
          match.range(at: $0).location != NSNotFound
        }
        let valueRange = captured.map { match.range(at: $0) } ?? match.range
        guard let locatorRange = Range(valueRange, in: text) else { throw DreamRunError.corruption }
        var value = String(text[locatorRange]).trimmingCharacters(in: .whitespaces)
        if captured == 4, let title = value.range(of: #"\s+["']"#, options: .regularExpression) {
          value = String(value[..<title.lowerBound])
        }
        if captured == nil {
          value = value.trimmingCharacters(in: CharacterSet(charactersIn: "()[],;.!?"))
        }
        guard value.lowercased().contains(".md") else { continue }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
          limitations.append(
            "A remote instruction-owner locator was not fetched; owner coverage is incomplete.")
          continue
        }
        let file: URL
        if value.hasPrefix("file:") {
          guard let url = URL(string: value), url.isFileURL else {
            limitations.append(
              "An unsupported instruction-owner locator was not opened; owner coverage is incomplete."
            )
            continue
          }
          guard url.host == nil || url.host == "" || url.host == "localhost" else {
            limitations.append(
              "A remote instruction-owner locator was not fetched; owner coverage is incomplete.")
            continue
          }
          file = url
        } else if value.contains(":") || value.contains("\\") || value.contains("\0") {
          limitations.append(
            "An unsupported instruction-owner locator was not opened; owner coverage is incomplete."
          )
          continue
        } else if value.hasPrefix("/") {
          file = URL(fileURLWithPath: value)
        } else {
          file = directory.appendingPathComponent(value)
        }
        guard file.pathExtension.lowercased() == "md" else { continue }
        let name = file.lastPathComponent.lowercased()
        let lineRange = text.lineRange(for: matchRange)
        let line = String(text[lineRange]).lowercased()
        guard
          ["agents.md", "skill.md"].contains(name)
            || ["owner", "instruction", "style", "policy"].contains(where: { name.contains($0) })
            || line.contains("owner") || line.contains("instruction")
        else { continue }
        _ = try captureOwner(file.standardizedFileURL, scope: scope)
      }
    }
    if let globalAgents {
      do {
        guard let resolved = realpath(globalAgents.path, nil) else {
          if errno == ENOENT { throw DreamRunError.missingPayload }
          throw DreamRunError.unsafeState
        }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved))
        if let text = try captureOwner(canonical, scope: .global) {
          try locators(text, directory: canonical.deletingLastPathComponent(), scope: .global)
        }
      } catch DreamRunError.missingPayload {
        limitations.append(
          "The explicit global AGENTS.md locator is missing; global owner coverage is incomplete.")
      }
    } else {
      limitations.append(
        "No global AGENTS.md locator was supplied; global owner coverage is incomplete.")
    }
    for project in projectRoots.values.sorted(by: { $0.root.path < $1.root.path }) {
      if let text = try captureOwner(
        project.root.appendingPathComponent("AGENTS.md"), scope: .project(project.key))
      {
        try locators(text, directory: project.root, scope: .project(project.key))
      }
    }
    let scopesBySource = Dictionary(uniqueKeysWithValues: scopes.map { ($0.source, $0) })
    let recordsByWitness = Dictionary(
      ([run.batch] + relatedBatches).flatMap(\.exactSourceRecords).map {
        (OwnerRecordKey($0.witness), $0)
      }, uniquingKeysWith: { first, _ in first })
    var parsedRecords: Set<OwnerRecordKey> = []
    for evidence in catalogue {
      guard let cwd = evidence.projectScope,
        let pinned = scopesBySource[evidence.id]
      else { continue }
      let scope: DreamMemoryScope
      switch pinned.resolution {
      case .project(let key, _): scope = .project(key)
      case .outsideGit: scope = .global
      case .unresolved: continue
      }
      if let bytes = recordsByWitness[OwnerRecordKey(evidence.witness)]?.bytes,
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let message = object["message"] as? [String: Any], message["role"] as? String == "user"
      {
        guard parsedRecords.insert(OwnerRecordKey(evidence.witness)).inserted else { continue }
        let texts: [String]
        if let text = message["content"] as? String {
          texts = [text]
        } else {
          texts = (message["content"] as? [[String: Any]] ?? []).compactMap {
            $0["type"] as? String == "text" ? $0["text"] as? String : nil
          }
        }
        for text in texts { try locators(text, directory: URL(fileURLWithPath: cwd), scope: scope) }
      } else {
        try locators(evidence.exactText, directory: URL(fileURLWithPath: cwd), scope: scope)
      }
    }
    limitations.append(
      "Owner coverage includes only root AGENTS.md and grounded local Markdown locators; no recursive search was performed."
    )
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    if let protect { try protect(DreamSourceProtection.authority(snapshot, owners: owners)) }
    let predecessors = try rejectedPredecessors(
      snapshot: snapshot, evidence: catalogue, current: run.batch,
      excludedSessionIDs: excludedSessionIDs, limits: decisionLimits, limitations: &limitations)
    if let protect, !predecessors.isEmpty {
      try protect(DreamSourceProtection.rejectedPredecessors(predecessors))
    }
    let context = try DreamDecisionContext(
      run: run, snapshot: snapshot, scopes: scopes, owners: owners,
      addedDate: formatter.string(from: date), limits: decisionLimits,
      limitations: limitations.reduce(into: [String]()) { values, value in
        if !values.contains(value) { values.append(value) }
      }, deviceKey: deviceKey, projectBindings: projectBindings,
      relatedBatches: relatedBatches, rejectedPredecessors: predecessors)
    guard context.canonicalBytes.count <= limits.maximumFrozenBytes else {
      throw DreamRunError.limitExceeded
    }
    return context
  }

  private func selectRetainedBatches(
    current: PreparedSessionBatch, retained: [PreparedSessionBatch],
    excludedSessionIDs: Set<String>, limitations: inout [String]
  ) throws -> [PreparedSessionBatch] {
    let inputLimits = try DreamInputLimits()
    let maximumBytes = min(limits.maximumFrozenBytes, 4_194_304)
    var bindingBytes = try DreamRunEncoding.batchBinding(
      current, maximumBytes: limits.maximumFrozenBytes
    ).count
    guard bindingBytes < maximumBytes else { return [] }
    var records = current.evidence.count
    var keptBytes = current.keptBytes
    var sessions = Set(current.evidence.map { $0.id.citation.session })
    var projects = Set(current.evidence.compactMap(\.projectScope))
    let currentPaths = Set(current.admittedViews.map(\.path))
    var selected: [PreparedSessionBatch] = []
    for batch in retained.reversed() {
      guard !batch.evidence.isEmpty,
        (try? batch.requireNoExcludedSessions(excludedSessionIDs)) != nil,
        batch.evidence.allSatisfy({
          sessions.contains($0.id.citation.session)
            || $0.projectScope.map { !$0.isEmpty && projects.contains($0) } == true
        }),
        batch.evidence.count <= inputLimits.maximumBatchRecords - records,
        batch.keptBytes <= inputLimits.maximumBatchBytes - keptBytes
      else { continue }
      guard
        batch.evidence.allSatisfy({
          $0.originalWitness != nil && currentPaths.contains($0.witness.relativePath.rawValue)
        })
      else {
        limitations.append(
          "A related retained window lacked a currently verified admitted source view and was not supplied."
        )
        continue
      }
      guard
        batch.selections.allSatisfy({ selection in
          batch.evidence.contains { $0.id.citation.session == selection.citation.session }
        })
      else { continue }
      let bytes = try DreamRunEncoding.batchBinding(batch, maximumBytes: limits.maximumFrozenBytes)
      guard bytes.count <= maximumBytes - bindingBytes else { continue }
      selected.append(batch)
      bindingBytes += bytes.count
      keptBytes += batch.keptBytes
      records += batch.evidence.count
      sessions.formUnion(batch.evidence.map { $0.id.citation.session })
      projects.formUnion(batch.evidence.compactMap(\.projectScope))
    }
    return selected
  }

  private func rejectedPredecessors(
    snapshot: ApprovedDecisionSnapshot, evidence: [PrimaryTextEvidence],
    current: PreparedSessionBatch,
    excludedSessionIDs: Set<String>, limits: DreamDecisionLimits, limitations: inout [String]
  ) throws -> [DreamRejectedPredecessor] {
    let findings = try MemoryQueueAuthority.rejectedFindings(
      git: Git(repo: memoryRepository, environment: ProcessInfo.processInfo.environment),
      repository: memoryRepository, sourceBinding: reviewSourceBinding().rawValue)
    let paths = Set(snapshot.documents.map(\.path))
    let sessions = Set(evidence.map { $0.id.citation.session })
    let projects = Set(evidence.compactMap(\.projectScope))
    let eligible = findings.filter { finding in
      let sources = finding.evidence + finding.contradictions.compactMap(\.evidence)
      return paths.contains(finding.path) && !sources.isEmpty
        && sources.allSatisfy {
          !excludedSessionIDs.contains($0.session)
            && (sessions.contains($0.session)
              || $0.projectScope.map { !$0.isEmpty && projects.contains($0) } == true)
        }
    }
    guard !eligible.isEmpty else { return [] }
    let byRevision = Dictionary(uniqueKeysWithValues: eligible.map { ($0.revision, $0) })
    var verified: Set<String> = []
    _ = try loadChain(completed: { bundle in
      for change in bundle.changes {
        guard let finding = byRevision[change.id.rawValue] else { continue }
        guard finding.path == change.path, finding.proposed == change.after,
          finding.before == (change.before ?? Data()), finding.frozenBase == change.base,
          finding.operation == change.operation.rawValue, finding.reason == change.reason,
          finding.evidence == (try change.sources.map(MemoryQueueEvidence.init)),
          finding.contradictions == (try change.contradictions.map(MemoryQueueConflict.init)),
          finding.inputDigest == change.inputHash.rawValue,
          finding.contextDigest == change.contextHash.rawValue,
          finding.responseDigest == change.responseHash.rawValue
        else { throw DreamRunError.corruption }
        verified.insert(finding.revision)
      }
    })
    guard verified.count == eligible.count else { throw DreamRunError.corruption }
    let currentPaths = Set(current.admittedViews.map(\.path))
    let currentSessions = Set(
      current.positionsAfter.filter {
        currentPaths.contains($0.relativePath.rawValue)
      }.map { $0.sessionID.rawValue })
    var catalogue: [DreamRejectedPredecessor] = []
    for finding in eligible.reversed() {
      let priorClaim = try DreamSourceProtection.text(finding.proposed)
      guard !priorClaim.isEmpty, finding.proposed.count <= limits.maximumBeforeBytes else {
        continue
      }
      let sources = finding.evidence + finding.contradictions.compactMap(\.evidence)
      guard
        sources.allSatisfy({
          $0.admittedRecordDigest != nil && currentPaths.contains($0.relativePath)
            && currentSessions.contains($0.session)
        })
      else {
        limitations.append(
          "A rejected predecessor lacked a currently verified admitted source view and was not supplied; its native review state is unchanged."
        )
        continue
      }
      let predecessor = DreamRejectedPredecessor(
        revision: finding.revision, path: finding.path, priorClaim: priorClaim,
        sourceSessions: Set(sources.map(\.session)).sorted())
      guard catalogue.count < 64,
        try DreamRunEncoding.encode(catalogue + [predecessor]).count <= limits.maximumMetadataBytes
      else { continue }
      catalogue.append(predecessor)
    }
    return catalogue
  }

  private struct OwnerRecordKey: Hashable {
    let path: SourceRelativePath
    let range: Range<UInt64>
    let hash: SourceDigest

    init(_ witness: RecordWitness) {
      path = witness.relativePath
      range = witness.byteRange
      hash = witness.rawRecordHash
    }
  }

  private struct SealedRun {
    let admission: DreamRunEncoding.Admission
    let admissionHash: SourceDigest
    let run: FrozenDreamRun
    let context: DreamDecisionContext
    let request: DreamModelRequest
    let rendering: DreamRequestRendering
    let directory: DreamStateDirectory
  }

  private struct SuccessfulChain {
    let record: DreamRunEncoding.Generation
    let hash: SourceDigest
    let hashes: [UInt64: String]
  }

  private func bounded<T: Encodable>(_ value: T) throws -> Data {
    let bytes = try DreamRunEncoding.encode(value)
    guard bytes.count <= limits.maximumFrozenBytes else { throw DreamRunError.limitExceeded }
    return bytes
  }

  private func install<T: Encodable>(_ value: T, name: String, directory: DreamStateDirectory)
    throws
  {
    try persist(bounded(value), name: name, directory: directory, isReplacing: false)
  }

  private func save(generation: UInt64, hash: SourceDigest, sealed: SealedRun? = nil) throws {
    let state = DreamRunEncoding.State(
      schemaVersion: 2, generation: generation, generationHash: hash.rawValue,
      admissionHash: sealed?.admissionHash.rawValue, runID: sealed?.run.runID)
    try persist(bounded(state), name: "state.json", directory: root, isReplacing: true)
  }

  private func pending(
    _ sealed: SealedRun, reason: DreamPendingReason, proposals: [DreamProposalReceipt] = [],
    validationError: DreamDecisionError? = nil, callSelection: DreamSelectedCall? = nil
  ) -> DreamTransactionResult {
    .pending(
      DreamPendingReport(
        runID: sealed.run.runID, generation: sealed.run.progress.generation,
        approvedBase: sealed.run.approvedBase, inputHash: sealed.run.inputHash,
        contextHash: sealed.context.contextHash, requestHash: sealed.request.requestHash,
        proposals: proposals, reason: reason, validationError: validationError,
        callSelection: callSelection))
  }

  private func loadChain(
    completed: ((VerifiedDreamReviewCandidates) throws -> Void)? = nil,
    capture: ((SealedRun, DreamRunEncoding.Generation, SourceDigest) throws -> Void)? = nil
  ) throws -> SuccessfulChain {
    let generations = try root.child("generations")
    let installed = Set(try generations.names().filter { !$0.hasPrefix(".pending-") })
    guard !installed.isEmpty else { throw DreamRunError.missingPayload }
    var priorViews: [String: DreamAdmittedView] = [:]
    var previous: DreamRunEncoding.Generation?
    var previousHash: SourceDigest?
    var hashes: [UInt64: String] = [:]
    for index in 0..<installed.count {
      let generation = UInt64(index)
      let name = "\(generation).json"
      guard installed.contains(name) else { throw DreamRunError.corruption }
      let bytes = try generations.read(name, maximum: limits.maximumFrozenBytes)
      let record = try DreamRunEncoding.decode(DreamRunEncoding.Generation.self, bytes: bytes)
      let progress = try record.progress.domain()
      guard record.bindingHash == bindingHash.rawValue, progress.generation == generation,
        progress.positions.count <= limits.maximumPositions,
        record.predecessorHash == previousHash?.rawValue
      else { throw DreamRunError.corruption }
      if generation == 0 {
        guard progress.positions.isEmpty, record.runID == nil, record.admissionHash == nil,
          record.completionHash == nil
        else { throw DreamRunError.corruption }
      } else {
        guard let previous, let previousHash, let runID = record.runID,
          DreamRunEncoding.isRunID(runID), let completionHash = record.completionHash,
          let admissionHash = record.admissionHash
        else { throw DreamRunError.corruption }
        let priorChain = SuccessfulChain(record: previous, hash: previousHash, hashes: hashes)
        let sealed = try loadAdmission(generation: generation - 1, chain: priorChain)
        guard sealed.run.runID == runID, sealed.admissionHash.rawValue == admissionHash else {
          throw DreamRunError.corruption
        }
        for view in sealed.run.batch.admittedViews {
          if let prior = priorViews[view.path] { try view.requireExtension(of: prior) }
          priorViews[view.path] = view
        }
        let outcome = try validatedOutcome(sealed)
        let decisionsBytes = try sealed.directory.read(
          "decisions.json", maximum: limits.maximumFrozenBytes)
        guard decisionsBytes == (try bounded(outcome.record)) else {
          throw DreamRunError.corruption
        }
        let receipts = try savedReceipts(
          sealed, plans: outcome.plans, decisionsBytes: decisionsBytes)
        guard receipts.count == outcome.plans.count else { throw DreamRunError.missingPayload }
        let completion = try completionRecord(
          sealed, outcome: outcome, decisionsBytes: decisionsBytes, receipts: receipts)
        let completionBytes = try sealed.directory.read(
          "completion.json", maximum: limits.maximumFrozenBytes)
        guard completionBytes == (try bounded(completion)),
          SourceDigest(bytes: completionBytes).rawValue == completionHash,
          progress == (try completion.progress.domain())
        else { throw DreamRunError.corruption }
        try capture?(sealed, record, SourceDigest(bytes: bytes))
        if let completed {
          let memory = try MemoryStore(repo: memoryRepository)
          let reports = try zip(outcome.plans, receipts).map { plan, receipt in
            let report = try DreamProposalReceipt(
              planHash: SourceDigest(receipt.planHash), ref: receipt.ref, commit: receipt.commit,
              base: receipt.base, path: receipt.path, sources: plan.sources,
              contradictions: plan.contradictions)
            try memory.verifySavedProposal(plan: plan, receipt: report)
            return report
          }
          try completed(
            VerifiedDreamReviewCandidates(
              runID: runID, generation: generation, admissionHash: sealed.admissionHash,
              completionHash: SourceDigest(bytes: completionBytes),
              decisionsHash: SourceDigest(bytes: decisionsBytes), changes: outcome.atomicChanges,
              receipts: reports, limitations: sealed.context.limitations,
              recoveryCheckpointHash: try completion.recoveryCheckpointHash.map {
                try SourceDigest($0)
              },
              recoveryCheckpoint: try enrolledRecovery(sealed, outcome: outcome)))
        }
      }
      let hash = SourceDigest(bytes: bytes)
      hashes[generation] = hash.rawValue
      previous = record
      previousHash = hash
    }
    guard let previous, let previousHash else { throw DreamRunError.missingPayload }
    return SuccessfulChain(record: previous, hash: previousHash, hashes: hashes)
  }

  private func loadAdmission(generation: UInt64, chain: SuccessfulChain) throws -> SealedRun {
    let bytes = try root.child("admissions").read(
      "\(generation).json", maximum: DreamRunEncoding.maximumMetadataBytes)
    let admission = try DreamRunEncoding.decode(DreamRunEncoding.Admission.self, bytes: bytes)
    guard admission.bindingHash == bindingHash.rawValue, admission.generation == generation,
      chain.hashes[generation] == admission.predecessorHash,
      DreamRunEncoding.isRunID(admission.runID)
    else { throw DreamRunError.corruption }
    let directory = try root.child("runs").child(admission.runID)
    let input = try directory.read("input.json", maximum: limits.maximumFrozenBytes)
    let run = try DreamRunEncoding.frozen(
      bytes: input, runID: admission.runID, inputHash: SourceDigest(admission.inputHash),
      bindingHash: bindingHash, limits: limits)
    let generationBytes = try root.child("generations").read(
      "\(generation).json", maximum: limits.maximumFrozenBytes)
    let successful = try DreamRunEncoding.decode(
      DreamRunEncoding.Generation.self, bytes: generationBytes)
    guard run.progress == (try successful.progress.domain()),
      run.predecessorProgressHash?.rawValue == admission.predecessorHash,
      run.approvedBase == admission.base,
      try admission.selection.domain() == run.selection
    else { throw DreamRunError.corruption }
    let contextBytes = try directory.read("context.json", maximum: limits.maximumFrozenBytes)
    guard SourceDigest(bytes: contextBytes).rawValue == admission.contextHash else {
      throw DreamRunError.corruption
    }
    let context = try DreamRunEncoding.context(bytes: contextBytes, run: run)
    let requestBytes = try directory.read("request.json", maximum: limits.maximumFrozenBytes)
    guard SourceDigest(bytes: requestBytes).rawValue == admission.requestHash else {
      throw DreamRunError.corruption
    }
    let request = try DreamRunEncoding.decode(DreamRunEncoding.Request.self, bytes: requestBytes)
    let verified = try request.verifiedDomain(run: run, context: context, bytes: requestBytes)
    return SealedRun(
      admission: admission, admissionHash: SourceDigest(bytes: bytes), run: run,
      context: context, request: verified.request, rendering: verified.rendering,
      directory: directory)
  }

  private struct Outcome {
    let record: DreamRunEncoding.Decisions
    let plans: [SingleFileProposalPlan]
    let notes: [DreamDecisionNote]
    let atomicChanges: [AtomicMemoryChange]
  }

  private var maximumResponseEnvelopeBytes: Int {
    limits.maximumResponseBytes * 6 + DreamRunEncoding.maximumMetadataBytes
  }

  private typealias ResponseAttempt = DreamResponseAttempt

  private func attemptReader(_ sealed: SealedRun) -> DreamAttemptReader {
    DreamAttemptReader(
      directory: sealed.directory, run: sealed.run, context: sealed.context,
      baseline: sealed.request, rendering: sealed.rendering,
      admissionHash: sealed.admissionHash, limits: limits)
  }

  private func activeAttempt(_ sealed: SealedRun) throws -> ResponseAttempt {
    try attemptReader(sealed).verify().attempt
  }

  private func verifiedAttempt(_ sealed: SealedRun, attempt: ResponseAttempt) throws
    -> VerifiedDreamAttempt
  {
    var selected: VerifiedDreamAttempt?
    _ = try attemptReader(sealed).verify { value in
      if value.attempt.number == attempt.number { selected = value }
    }
    guard let selected else { throw DreamRunError.corruption }
    return selected
  }

  private func loadCallSelection(_ sealed: SealedRun, attempt: ResponseAttempt) throws
    -> DreamSelectedCall
  {
    guard let selection = try verifiedAttempt(sealed, attempt: attempt).selection else {
      throw DreamRunError.corruption
    }
    return selection
  }

  private func validatedOutcome(_ sealed: SealedRun, attempt supplied: ResponseAttempt? = nil)
    throws -> Outcome
  {
    let attempt = try supplied ?? activeAttempt(sealed)
    let run = sealed.run
    let validated: ValidatedDreamDecision?
    var responseHash: SourceDigest?
    if run.batch.evidence.isEmpty {
      guard !(try sealed.directory.isPresent("response.json")),
        !(try sealed.directory.isPresent("call-started.json"))
      else { throw DreamRunError.corruption }
      validated = nil
    } else {
      guard let durable = try verifiedAttempt(sealed, attempt: attempt).response else {
        throw DreamRunError.missingPayload
      }
      responseHash = durable.responseHash
      switch DreamDecision.assess(
        response: durable, context: sealed.context, rendering: sealed.rendering)
      {
      case .success(let result): validated = result
      case .failure(let rejection): throw rejection.error
      }
    }
    let plans = validated?.plans ?? []
    let notes = validated?.notes ?? []
    return Outcome(
      record: DreamRunEncoding.Decisions(
        schemaVersion: 2, admissionHash: sealed.admissionHash.rawValue,
        responseHash: responseHash?.rawValue, contextHash: sealed.context.contextHash.rawValue,
        plans: plans.map(DreamRunEncoding.Plan.init), notes: notes.map(DreamRunEncoding.Note.init),
        exclusionInputHash: validated == nil ? run.inputHash.rawValue : nil),
      plans: plans, notes: notes, atomicChanges: validated?.atomicChanges ?? [])
  }

  private func savedReceipts(
    _ sealed: SealedRun, plans: [SingleFileProposalPlan], decisionsBytes: Data
  ) throws -> [DreamRunEncoding.Receipt] {
    let directory = try sealed.directory.child("receipts")
    var receipts: [DreamRunEncoding.Receipt] = []
    for plan in plans {
      let hash = SourceDigest(bytes: try bounded(DreamRunEncoding.Plan(plan)))
      let name = hash.rawValue + ".json"
      if try directory.isPresent(name) {
        let bytes = try directory.read(name, maximum: limits.maximumFrozenBytes)
        let receipt = try DreamRunEncoding.decode(DreamRunEncoding.Receipt.self, bytes: bytes)
        guard bytes == (try bounded(receipt)) else { throw DreamRunError.corruption }
        guard receipt.admissionHash == sealed.admissionHash.rawValue,
          receipt.decisionsHash == SourceDigest(bytes: decisionsBytes).rawValue,
          receipt.planHash == hash.rawValue, receipt.base == plan.base, receipt.path == plan.path,
          receipt.ref == "refs/heads/proposals/\(receipt.commit)",
          [40, 64].contains(receipt.commit.utf8.count),
          receipt.commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw DreamRunError.corruption }
        receipts.append(receipt)
      }
    }
    return receipts
  }

  private func completionRecord(
    _ sealed: SealedRun, outcome: Outcome, decisionsBytes: Data,
    receipts: [DreamRunEncoding.Receipt]
  ) throws -> DreamRunEncoding.Completion {
    let generation = sealed.run.progress.generation
    let (next, isOverflow) = generation.addingReportingOverflow(1)
    guard !isOverflow else { throw DreamRunError.staleGeneration }
    let decisions = try DreamRunEncoding.decode(
      DreamRunEncoding.Decisions.self, bytes: decisionsBytes)
    let enrollment = try enrolledRecovery(sealed, outcome: outcome)
    return DreamRunEncoding.Completion(
      schemaVersion: enrollment == nil ? 2 : 3, admissionHash: sealed.admissionHash.rawValue,
      decisionsHash: SourceDigest(bytes: decisionsBytes).rawValue,
      predecessorHash: sealed.admission.predecessorHash, predecessorGeneration: generation,
      nextGeneration: next,
      progress: DreamRunEncoding.Progress(
        try DreamProgress(
          generation: next, positions: sealed.run.batch.positionsAfter)),
      receiptHashes: try receipts.map { SourceDigest(bytes: try bounded($0)).rawValue },
      notes: decisions.notes,
      tails: sealed.run.batch.unfinishedTails.map(DreamRunEncoding.Tail.init),
      isBacklog: sealed.run.batch.isBacklog,
      recoveryCheckpointHash: try enrollment.map { SourceDigest(bytes: try bounded($0)).rawValue })
  }

  private func finish(
    _ sealed: SealedRun, chain: SuccessfulChain, isRecovered: Bool, isCommitted: Bool
  ) throws -> DreamTransactionResult {
    _ = try acceptedCanonicalRoot(at: 1)
    let outcome: Outcome
    do { outcome = try validatedOutcome(sealed) } catch let error as DreamDecisionError {
      if isCommitted { throw DreamRunError.corruption }
      return pending(sealed, reason: .invalidDecision, validationError: error)
    }
    let enrollment = try enrolledRecovery(sealed, outcome: outcome)
    if !isCommitted, isCancelled() { return pending(sealed, reason: .cancelled) }
    if !sealed.run.batch.evidence.isEmpty {
      let attempt = try activeAttempt(sealed)
      let responseBytes = try sealed.directory.read(
        attempt.responseName, maximum: maximumResponseEnvelopeBytes)
      try persist(
        responseBytes, name: attempt.responseName, directory: sealed.directory, isReplacing: false)
    }
    let decisionsBytes = try bounded(outcome.record)
    try persist(
      decisionsBytes, name: "decisions.json", directory: sealed.directory, isReplacing: false)
    let receiptDirectory = try sealed.directory.child("receipts")
    _ = try savedReceipts(sealed, plans: outcome.plans, decisionsBytes: decisionsBytes)
    let memory = try MemoryStore(repo: memoryRepository)
    var receipts: [String: DreamRunEncoding.Receipt] = [:]
    let decisionsHash = SourceDigest(bytes: decisionsBytes)
    let planHashes = try Dictionary(
      uniqueKeysWithValues: outcome.plans.map {
        ($0.path, SourceDigest(bytes: try bounded(DreamRunEncoding.Plan($0))))
      })
    func recover(_ plan: SingleFileProposalPlan) throws {
      let planHash = planHashes[plan.path]!
      recoveryCount += 1
      if let recovered = try memory.recoverProposal(
        base: plan.base, path: plan.path, replacement: plan.replacement,
        reason: plan.reason, contradictions: plan.contradictions)
      {
        let receipt = DreamRunEncoding.Receipt(
          schemaVersion: 2, admissionHash: sealed.admissionHash.rawValue,
          decisionsHash: decisionsHash.rawValue,
          planHash: planHash.rawValue,
          ref: recovered.ref, commit: recovered.commit, base: recovered.base, path: plan.path)
        try install(receipt, name: planHash.rawValue + ".json", directory: receiptDirectory)
        receipts[plan.path] = receipt
      } else if try receiptDirectory.isPresent(planHash.rawValue + ".json") {
        throw DreamRunError.corruption
      }
    }
    func recoverAll() throws {
      for plan in outcome.plans { try recover(plan) }
    }
    func reports() throws -> [DreamProposalReceipt] {
      try outcome.plans.compactMap { plan in
        guard let receipt = receipts[plan.path] else { return nil }
        return try DreamProposalReceipt(
          planHash: SourceDigest(receipt.planHash), ref: receipt.ref, commit: receipt.commit,
          base: receipt.base, path: receipt.path, sources: plan.sources,
          contradictions: plan.contradictions)
      }
    }
    try recoverAll()
    if enrollment != nil, receipts.count != outcome.plans.count {
      if isCommitted { throw DreamRunError.corruption }
      return try pending(sealed, reason: .staleUnpublishedPlans, proposals: reports())
    }
    for plan in outcome.plans where receipts[plan.path] == nil {
      if isCommitted { throw DreamRunError.corruption }
      if isCancelled() { return try pending(sealed, reason: .cancelled, proposals: reports()) }
      guard try memory.approvedCommit() == sealed.run.approvedBase else {
        try recoverAll()
        if receipts.count == outcome.plans.count { break }
        return try pending(sealed, reason: .staleUnpublishedPlans, proposals: reports())
      }
      try beforePublication?(plan.path)
      do {
        _ = try memory.propose(
          base: plan.base, path: plan.path, replacement: plan.replacement,
          reason: plan.reason, contradictions: plan.contradictions)
      } catch {
        try recoverAll()
        if receipts.count != outcome.plans.count,
          try memory.approvedCommit() != sealed.run.approvedBase
        {
          return try pending(sealed, reason: .staleUnpublishedPlans, proposals: reports())
        }
        if receipts[plan.path] == nil { throw error }
      }
      try recover(plan)
    }
    guard receipts.count == outcome.plans.count else { throw DreamRunError.corruption }
    if !isCommitted, isCancelled() {
      return try pending(sealed, reason: .cancelled, proposals: reports())
    }
    let ordered = outcome.plans.map { receipts[$0.path]! }
    let completion = try completionRecord(
      sealed, outcome: outcome, decisionsBytes: decisionsBytes, receipts: ordered)
    let completionBytes = try bounded(completion)
    try persist(
      completionBytes, name: "completion.json", directory: sealed.directory, isReplacing: false)
    if !isCommitted, isCancelled() {
      return try pending(sealed, reason: .cancelled, proposals: reports())
    }
    let generation = DreamRunEncoding.Generation(
      schemaVersion: 2, bindingHash: bindingHash.rawValue,
      predecessorHash: sealed.admission.predecessorHash,
      admissionHash: sealed.admissionHash.rawValue,
      completionHash: SourceDigest(bytes: completionBytes).rawValue, runID: sealed.run.runID,
      progress: completion.progress)
    let generationBytes = try bounded(generation)
    do {
      try persist(
        generationBytes, name: "\(completion.nextGeneration).json",
        directory: root.child("generations"), isReplacing: false, isProgressCommit: !isCommitted)
    } catch is CancellationError {
      return try pending(sealed, reason: .cancelled, proposals: reports())
    }
    try save(generation: completion.nextGeneration, hash: SourceDigest(bytes: generationBytes))
    try beforeFinalReport?()
    return try .completed(
      DreamCompletionReport(
        runID: sealed.run.runID, predecessorGeneration: sealed.run.progress.generation,
        generation: completion.nextGeneration, approvedBase: sealed.run.approvedBase,
        proposals: reports(), notes: outcome.notes, isBacklog: sealed.run.batch.isBacklog,
        isRecovered: isRecovered))
  }

  private func fault(_ event: DreamPersistenceEvent) throws {
    do { try persistenceFault?(event) } catch { throw DreamRunError.persistenceFailure }
  }

  private func synchronize(_ directory: DreamStateDirectory, name: String) throws {
    try fault(.beforeDirectorySync(name))
    guard syncCall(directory.descriptor) == 0 else { throw DreamRunError.persistenceFailure }
    try fault(.afterDirectorySync(name))
  }

  private func persist(
    _ bytes: Data, name: String, directory: DreamStateDirectory, isReplacing: Bool,
    isProgressCommit: Bool = false, isPromptRelocation: Bool = false,
    beforeInstall: () throws -> Void = {}
  ) throws {
    let retained = try root.retainedBytes(maximum: limits.maximumStateBytes, isDreamAuthority: true)
    if !isReplacing, try directory.isPresent(name) {
      guard !isPromptRelocation else {
        throw MemoryError("a prompt relocation record already exists")
      }
      let maximum = max(
        limits.maximumFrozenBytes,
        limits.maximumResponseBytes * 6 + DreamRunEncoding.maximumMetadataBytes)
      guard try directory.read(name, maximum: maximum) == bytes else {
        throw DreamRunError.corruption
      }
      try directory.synchronizeFile(name)
      try synchronize(directory, name: name)
      return
    }
    guard
      bytes.count
        <= (isPromptRelocation
          ? PromptRelocationRecord.maximumBytes : limits.maximumStateBytes - retained),
      !isPromptRelocation
        || (directory === root && DreamRelocationRole.allCases.contains(where: { $0.recordName == name }) && !isReplacing)
    else { throw DreamRunError.limitExceeded }
    let temporary = ".pending-" + UUID().uuidString.lowercased()
    let file = openat(
      directory.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw DreamRunError.persistenceFailure }
    var isClosed = false
    defer {
      if !isClosed { _ = close(file) }
      if isPromptRelocation { _ = unlinkat(directory.descriptor, temporary, 0) }
    }
    try directory.verifyFile(file)
    try fault(.beforeWrite(name))
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = writeCall(
          file, buffer.baseAddress! + offset, min(buffer.count - offset, max(1, writeChunkBytes)))
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw DreamRunError.persistenceFailure }
        offset += count
        try fault(.afterWriteChunk(name))
      }
    }
    try fault(.afterWrite(name))
    try fault(.beforeFileSync(name))
    guard syncCall(file) == 0 else { throw DreamRunError.persistenceFailure }
    try fault(.afterFileSync(name))
    guard close(file) == 0 else { throw DreamRunError.persistenceFailure }
    isClosed = true
    try fault(.beforeInstall(name))
    try beforeInstall()
    if isProgressCommit, isCancelled() { throw CancellationError() }
    if isReplacing, try directory.isPresent(name) {
      _ = try directory.read(name, maximum: DreamRunEncoding.maximumMetadataBytes)
    }
    guard installCall(directory.descriptor, temporary, name, isReplacing) == 0 else {
      throw DreamRunError.persistenceFailure
    }
    try fault(.afterInstall(name))
    try synchronize(directory, name: name)
  }

  static func validateStateIdentity(_ status: stat, isDirectory: Bool) throws {
    guard status.st_uid == geteuid(),
      status.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG),
      status.st_mode & 0o7777 == (isDirectory ? 0o700 : 0o600),
      isDirectory || status.st_nlink == 1
    else { throw DreamRunError.unsafeState }
  }

  private func acceptedCanonicalRoot(at index: Int) throws -> URL {
    let source = configuredRoots[index]
    let canonical = try Self.canonicalExisting(suppliedRoots[index])
    guard Data(canonical.path.utf8) == Data(source.path.utf8),
      Data(try Self.canonicalExisting(source).path.utf8) == Data(source.path.utf8)
    else {
      throw DreamRunError.unsafeState
    }
    return canonical
  }

  private static func canonicalExisting(_ url: URL) throws -> URL {
    guard let path = realpath(url.path, nil) else { throw DreamRunError.unsafeState }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
  }

  private static func isWithin(_ child: URL, _ parent: URL) -> Bool {
    child.path == parent.path || child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
  }

  private struct RootBinding: Codable {
    let schemaVersion: Int
    let sessions: String
    let memory: String
    let stripping: [String]
    let globalAgents: String?
    let originalRoots: [String]?
  }
}

final class DreamStateDirectory {
  let descriptor: Int32
  private let parent: DreamStateDirectory?

  private init(descriptor: Int32, parent: DreamStateDirectory? = nil) {
    self.descriptor = descriptor
    self.parent = parent
  }

  deinit { _ = close(descriptor) }

  static func openRoot(_ url: URL, isCreating: Bool = true) throws -> DreamStateDirectory {
    var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else { throw DreamRunError.unsafeState }
    var isClosed = false
    defer { if !isClosed { _ = close(current) } }
    let components = url.path.split(separator: "/").map(String.init)
    guard !components.isEmpty else { throw DreamRunError.unsafeState }
    var isCreated = false
    for (index, component) in components.enumerated() {
      var status = stat()
      if fstatat(current, component, &status, AT_SYMLINK_NOFOLLOW) != 0 {
        guard isCreating, errno == ENOENT, mkdirat(current, component, 0o700) == 0 else {
          throw DreamRunError.unsafeState
        }
        isCreated = true
        guard fsync(current) == 0 else { throw DreamRunError.persistenceFailure }
      } else {
        guard status.st_mode & S_IFMT == S_IFDIR else { throw DreamRunError.unsafeState }
        if isCreated || index == components.count - 1 { try verifyDirectory(status) }
      }
      let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw DreamRunError.unsafeState }
      guard close(current) == 0 else {
        _ = close(next)
        throw DreamRunError.persistenceFailure
      }
      current = next
      if isCreated || index == components.count - 1 {
        var opened = stat()
        guard fstat(current, &opened) == 0 else { throw DreamRunError.unsafeState }
        try verifyDirectory(opened)
      }
    }
    isClosed = true
    return DreamStateDirectory(descriptor: current)
  }

  private static func verifyDirectory(_ status: stat) throws {
    try DreamRunStore.validateStateIdentity(status, isDirectory: true)
  }

  func verifyFile(_ descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw DreamRunError.unsafeState }
    try DreamRunStore.validateStateIdentity(status, isDirectory: false)
  }

  func isPresent(_ name: String) throws -> Bool {
    var status = stat()
    if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return true }
    guard errno == ENOENT else { throw DreamRunError.unsafeState }
    return false
  }

  func child(_ name: String, isCreating: Bool = false) throws -> DreamStateDirectory {
    if isCreating {
      guard mkdirat(descriptor, name, 0o700) == 0 else { throw DreamRunError.persistenceFailure }
    }
    let file = openat(
      descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else {
      if errno == ENOENT { throw DreamRunError.missingPayload }
      throw DreamRunError.unsafeState
    }
    do {
      var status = stat()
      guard fstat(file, &status) == 0 else { throw DreamRunError.unsafeState }
      try Self.verifyDirectory(status)
      return DreamStateDirectory(descriptor: file, parent: self)
    } catch {
      _ = close(file)
      throw error
    }
  }

  func names(maximum: Int = 10_000, isDreamAuthority: Bool = false) throws -> [String] {
    let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard copy >= 0 else { throw DreamRunError.persistenceFailure }
    guard let directory = fdopendir(copy) else {
      _ = close(copy)
      throw DreamRunError.persistenceFailure
    }
    var isClosed = false
    defer { if !isClosed { _ = closedir(directory) } }
    var names: [String] = []
    var relocationCount = 0
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw DreamRunError.persistenceFailure }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      if name != ".", name != ".." {
        names.append(name)
        if isDreamAuthority, DreamRelocationRole.allCases.contains(where: { $0.recordName == name }) {
          relocationCount += 1
        }
      }
      guard names.count - relocationCount <= maximum else {
        throw DreamRunError.limitExceeded
      }
    }
    guard closedir(directory) == 0 else { throw DreamRunError.persistenceFailure }
    isClosed = true
    return names.sorted()
  }

  func retainedBytes(maximum: Int, depth: Int = 0, isDreamAuthority: Bool = false) throws -> Int {
    guard depth < 64 else { throw DreamRunError.limitExceeded }
    var directoryStatus = stat()
    guard fstat(descriptor, &directoryStatus) == 0 else { throw DreamRunError.unsafeState }
    try Self.verifyDirectory(directoryStatus)
    var total = 0
    for name in try names(isDreamAuthority: isDreamAuthority && depth == 0) {
      if isDreamAuthority, depth == 0,
        DreamRelocationRole.allCases.contains(where: { $0.recordName == name }) { continue }
      var status = stat()
      guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw DreamRunError.unsafeState
      }
      let count: Int
      if depth == 0, name == "timing.json", status.st_mode & S_IFMT == S_IFREG {
        guard status.st_size >= 0, UInt64(status.st_size) <= UInt64(maximum - total)
        else { throw DreamRunError.limitExceeded }
        count = Int(status.st_size)
      } else if status.st_mode & S_IFMT == S_IFDIR {
        count = try child(name).retainedBytes(maximum: maximum - total, depth: depth + 1)
      } else {
        let file = try openFile(name)
        var isClosed = false
        defer { if !isClosed { _ = close(file) } }
        guard fstat(file, &status) == 0, status.st_size >= 0,
          UInt64(status.st_size) <= UInt64(maximum - total)
        else { throw DreamRunError.limitExceeded }
        count = Int(status.st_size)
        guard close(file) == 0 else { throw DreamRunError.persistenceFailure }
        isClosed = true
      }
      guard count <= maximum - total else { throw DreamRunError.limitExceeded }
      total += count
    }
    return total
  }

  private func openFile(_ name: String) throws -> Int32 {
    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else {
      if errno == ENOENT { throw DreamRunError.missingPayload }
      throw DreamRunError.unsafeState
    }
    do { try verifyFile(file) } catch {
      _ = close(file)
      throw error
    }
    return file
  }

  func read(_ name: String, maximum: Int) throws -> Data {
    let file = try openFile(name)
    var isClosed = false
    defer { if !isClosed { _ = close(file) } }
    var status = stat()
    guard fstat(file, &status) == 0, status.st_size >= 0,
      UInt64(status.st_size) <= UInt64(maximum)
    else { throw DreamRunError.limitExceeded }
    var bytes = Data(count: Int(status.st_size))
    try bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.read(file, buffer.baseAddress! + offset, buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw DreamRunError.corruption }
        offset += count
      }
    }
    var extra: UInt8 = 0
    guard Darwin.read(file, &extra, 1) == 0 else { throw DreamRunError.corruption }
    guard close(file) == 0 else { throw DreamRunError.persistenceFailure }
    isClosed = true
    return bytes
  }

  func synchronizeFile(_ name: String) throws {
    let file = try openFile(name)
    var isClosed = false
    defer { if !isClosed { _ = close(file) } }
    guard fsync(file) == 0, close(file) == 0 else { throw DreamRunError.persistenceFailure }
    isClosed = true
  }

  func openReadLock() throws -> Int32 { try openFile("writer.lock") }

  func openLock() throws -> (descriptor: Int32, isCreated: Bool) {
    let file = openat(descriptor, "writer.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if file >= 0 {
      do { try verifyFile(file) } catch {
        _ = close(file)
        throw error
      }
      return (file, false)
    }
    guard errno == ENOENT else { throw DreamRunError.unsafeState }
    let existing = try names()
    if existing.contains("writer.lock") { return try openLock() }
    guard existing.isEmpty else { throw DreamRunError.missingPayload }
    let created = openat(
      descriptor, "writer.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    if created < 0 {
      if errno == EEXIST { return try openLock() }
      throw DreamRunError.persistenceFailure
    }
    do {
      try verifyFile(created)
      guard fsync(created) == 0, fsync(descriptor) == 0 else {
        throw DreamRunError.persistenceFailure
      }
      return (created, true)
    } catch {
      _ = close(created)
      throw error
    }
  }

  func verifyLock(_ file: Int32) throws {
    try verifyFile(file)
    var held = stat()
    var named = stat()
    guard fstat(file, &held) == 0,
      fstatat(descriptor, "writer.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
      held.st_dev == named.st_dev, held.st_ino == named.st_ino
    else { throw DreamRunError.unsafeState }
  }
}
