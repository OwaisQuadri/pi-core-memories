import CoreMemories
import Foundation

struct WorkspaceSnapshot: Sendable {
  let configuration: MemoryConfiguration
  let catalog: MemoryManagementResult?
  let drafts: [MemoryDraft]
  let draftRecoveries: [MemoryDraftRecovery]
  let inspection: DreamInspection?
  let invocationStatus: DreamInvocationStatus?
  let invocationStatusFailure: String?
  let failures: [String]
}

struct SavedRecoveryPresentation: Sendable {
  let runID: String
  let suggestions: [SavedSuggestionSummary]
  var actionableCount: Int { suggestions.filter { $0.blocker == nil }.count }
}

func configurationIdentity(_ configuration: MemoryConfiguration) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(configuration)
}

actor Workspace {
  let configURL: URL
  var configuration: MemoryConfiguration = .defaults
  var draftStore: MemoryDraftStore?
  var currentDraft: MemoryDraft?
  var review: MemoryReviewController?
  var reviewPreparationFailure: String?
  var session: MemoryBatchSession?
  var durableRevision: UInt64?
  var pendingPersistence: NativePendingPersistence?
  var unresolvedSave: MemoryDraft?
  var draftRecoveries: [MemoryDraftRecovery] = []
  private(set) var isLoaded = false
  let persistence: NativeBatchPersistence
  private var recovery: (DreamRunStore, SavedDreamRecoveryPreview, Data, String)?

  init(configURL: URL, persistence: NativeBatchPersistence = NativeBatchPersistence()) {
    self.configURL = configURL
    self.persistence = persistence
  }

  func load() throws -> WorkspaceSnapshot {
    isLoaded = false
    configuration = try MemoryConfiguration.load(from: configURL)
    isLoaded = true
    return refresh()
  }

  func refresh() -> WorkspaceSnapshot {
    recovery = nil
    var failures: [String] = []
    var catalog: MemoryManagementResult?
    var inspection: DreamInspection?
    var drafts: [MemoryDraft] = []
    do {
      catalog = try MemoryManagement(repository: configuration.memoryURL).execute(
        .init(operation: .list))
    } catch { failures.append(String(describing: error)) }
    do { inspection = try DreamInspection.read(stateRoot: configuration.stateURL) } catch {
      failures.append(String(describing: error))
    }
    if FileManager.default.fileExists(atPath: configuration.journal) {
      do {
        let store = try editorStore()
        let result = try store.inspectDrafts(review: optionalReviewCatalog().controller)
        drafts = result.drafts
        draftRecoveries = result.recoveryRequired
        if currentDraft == nil, draftRecoveries.isEmpty { currentDraft = drafts.last }
      } catch { failures.append(String(describing: error)) }
    }
    var invocationStatus: DreamInvocationStatus?
    var invocationStatusFailure: String?
    do {
      invocationStatus = try DreamInvocationStatus.read(
        configuration: configuration, inspection: inspection)
    } catch {
      invocationStatusFailure = "Saved invocation status unavailable: \(error)"
    }
    return WorkspaceSnapshot(
      configuration: configuration, catalog: catalog,
      drafts: drafts, draftRecoveries: draftRecoveries, inspection: inspection,
      invocationStatus: invocationStatus,
      invocationStatusFailure: invocationStatusFailure, failures: failures)
  }

  func configure(_ value: MemoryConfiguration) throws {
    guard pendingPersistence == nil, unresolvedSave == nil,
      session?.projection.draft.batch?.items.isEmpty != false,
      currentDraft?.batch?.items.isEmpty != false,
      currentDraft?.operations.isEmpty != false
    else {
      throw WorkspaceError("Save or discard the active draft before changing configuration")
    }
    if let draft = session?.projection.draft ?? currentDraft {
      try editorStore().discard(
        draftID: draft.draftID, expectedRevision: durableRevision ?? draft.revision)
    }
    session = nil
    currentDraft = nil
    durableRevision = nil
    try value.save(to: configURL)
    configuration = value
    draftStore = nil
    review = nil
    draftRecoveries = []
    recovery = nil
  }

  func checkoutPreview() throws -> MemoryReviewCheckoutPreview {
    try MemoryManagement(repository: configuration.memoryURL).checkoutPreview()
  }

  func detach(_ preview: MemoryReviewCheckoutPreview) throws {
    try MemoryManagement(repository: configuration.memoryURL).confirmDetach(preview)
  }

  func prepareSavedRecovery(
    runID: String, profile: MemoryConfiguration, base: String
  ) throws -> SavedRecoveryPresentation {
    recovery = nil
    let identity = try verifyRecoveryProfile(profile, base: base)
    let sources = try configuration.reviewSources()
    let preview = try sources.previewSavedRecovery(runID: runID)
    recovery = (sources, preview, identity, base)
    return SavedRecoveryPresentation(runID: runID, suggestions: preview.suggestions)
  }

  func confirmSavedRecovery(profile: MemoryConfiguration, base: String) throws {
    guard let (sources, preview, identity, retainedBase) = recovery else {
      throw WorkspaceError("Prepare saved suggestions again")
    }
    recovery = nil
    guard try verifyRecoveryProfile(profile, base: base) == identity, retainedBase == base else {
      throw WorkspaceError("Profile or saved memories changed; prepare again")
    }
    guard case .completed = try sources.confirmSavedRecovery(preview) else {
      throw WorkspaceError("Saved suggestions are still waiting; prepare again")
    }
  }

  func cancelSavedRecovery() { recovery = nil }

  private func verifyRecoveryProfile(_ profile: MemoryConfiguration, base: String) throws -> Data {
    let identity = try configurationIdentity(configuration)
    guard try configurationIdentity(profile) == identity,
      try configurationIdentity(MemoryConfiguration.load(from: configURL)) == identity,
      try MemoryStore(repo: configuration.memoryURL).approvedCommit() == base
    else {
      throw WorkspaceError("Load the matching profile and refresh saved memories first")
    }
    return identity
  }

  func artifact(_ artifact: DreamArtifact) throws -> String {
    let bytes = try DreamInspection.artifactBytes(artifact, stateRoot: configuration.stateURL)
    guard bytes.count <= 1_048_576 else {
      throw WorkspaceError("artifact exceeds the 1 MiB viewer limit; reveal it in Finder")
    }
    let value = try JSONSerialization.jsonObject(with: bytes)
    return String(
      decoding: try JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      as: UTF8.self)
  }

  func reveal(_ artifact: DreamArtifact) throws -> URL {
    try DreamInspection.revealURL(artifact, stateRoot: configuration.stateURL)
  }

  func revealMemory(path: String) throws -> URL {
    guard MemoryDocument.isAllowedPath(path) else { throw WorkspaceError("invalid memory path") }
    let file = configuration.memoryURL.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: file.path) { return try canonicalExistingFile(file) }
    return configuration.memoryURL.resolvingSymlinksInPath()
  }

  func editorStore() throws -> MemoryDraftStore {
    if let draftStore { return draftStore }
    let store = try MemoryDraftStore(
      repository: configuration.memoryURL,
      journal: URL(fileURLWithPath: configuration.journal))
    draftStore = store
    return store
  }

  func reviewController() throws -> MemoryReviewController {
    if let review { return review }
    let sources = try configuration.reviewSources()
    let controller = try MemoryReviewController(
      repository: sources.acceptedSources.memory,
      stateRoot: URL(fileURLWithPath: configuration.reviewState), sources: sources,
      environment: ProcessInfo.processInfo.environment)
    review = controller
    return controller
  }
}

struct WorkspaceError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
