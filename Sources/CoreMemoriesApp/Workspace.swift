import CoreMemories
import Foundation

struct WorkspaceSnapshot: Sendable {
  let configuration: MemoryConfiguration
  let catalog: MemoryManagementResult?
  let drafts: [MemoryDraft]
  let inspection: DreamInspection?
  let invocationStatus: DreamInvocationStatus?
  let failures: [String]
}

actor Workspace {
  let configURL: URL
  private var configuration: MemoryConfiguration = .defaults
  private var draftStore: MemoryDraftStore?
  private var currentDraft: MemoryDraft?
  private var review: MemoryReviewController?

  init(configURL: URL) { self.configURL = configURL }

  func load() throws -> WorkspaceSnapshot {
    configuration = try MemoryConfiguration.load(from: configURL)
    return refresh()
  }

  func refresh() -> WorkspaceSnapshot {
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
        drafts = try store.list()
        if currentDraft == nil { currentDraft = drafts.last }
      } catch { failures.append(String(describing: error)) }
    }
    let invocationStatus = try? DreamInvocationStatus.read(
      configuration: configuration, inspection: inspection)
    return WorkspaceSnapshot(
      configuration: configuration, catalog: catalog,
      drafts: drafts, inspection: inspection, invocationStatus: invocationStatus,
      failures: failures)
  }

  func configure(_ value: MemoryConfiguration) throws {
    guard currentDraft == nil else {
      throw WorkspaceError("Save or discard the active draft before changing configuration")
    }
    try value.save(to: configURL)
    configuration = value
    draftStore = nil
    review = nil
  }

  func autosave(_ operations: [MemoryManagementRequest], base: String) throws -> MemoryDraft {
    let store = try editorStore()
    guard let draft = currentDraft else {
      let created = try store.create(base: base, operations: operations)
      currentDraft = created
      return created
    }
    guard draft.baseCommit == base else {
      throw WorkspaceError("active draft has a different base; reconcile or discard it first")
    }
    let updated = try store.update(
      draftID: draft.draftID, expectedRevision: draft.revision, operations: operations)
    currentDraft = updated
    return updated
  }

  func restore(_ draft: MemoryDraft) throws {
    guard let latest = try editorStore().list().first(where: { $0.draftID == draft.draftID }),
      latest.revision == draft.revision
    else {
      throw WorkspaceError("draft changed; refresh recovery")
    }
    currentDraft = latest
  }

  func save() throws -> MemoryDraftReceipt {
    guard let draft = currentDraft else { throw WorkspaceError("no active draft") }
    let store = try editorStore()
    let receipt = try store.save(
      draftID: draft.draftID, expectedRevision: draft.revision,
      idempotencyKey: "native-save-\(draft.revision)")
    try store.discard(draftID: draft.draftID, expectedRevision: draft.revision)
    currentDraft = nil
    return receipt
  }

  func discard() throws {
    if let draft = currentDraft {
      try editorStore().discard(draftID: draft.draftID, expectedRevision: draft.revision)
    }
    currentDraft = nil
  }

  func checkoutPreview() throws -> MemoryReviewCheckoutPreview {
    try MemoryManagement(repository: configuration.memoryURL).checkoutPreview()
  }

  func detach(_ preview: MemoryReviewCheckoutPreview) throws {
    try MemoryManagement(repository: configuration.memoryURL).confirmDetach(preview)
  }

  func candidates() throws -> [MemoryReviewCandidate] { try reviewController().list() }

  func preview(_ id: SourceDigest) throws -> MemoryReviewPreview {
    try reviewController().preview(candidateID: id, clockDate: Date())
  }

  func approve(_ preview: MemoryReviewPreview) throws -> MemoryReviewApproval {
    try reviewController().apply(preview)
  }

  func disposition(_ id: SourceDigest, isRejected: Bool) throws {
    if isRejected {
      try reviewController().reject(candidateID: id)
    } else {
      try reviewController().deferCandidate(candidateID: id)
    }
  }

  func confirmReviewed(_ entry: ManagedMemoryEntry, base: String) throws {
    _ = try MemoryManagement(repository: configuration.memoryURL).confirmReviewed(
      base: base, entry: entry)
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

  private func editorStore() throws -> MemoryDraftStore {
    if let draftStore { return draftStore }
    let store = try MemoryDraftStore(
      repository: configuration.memoryURL,
      journal: URL(fileURLWithPath: configuration.journal))
    draftStore = store
    return store
  }

  private func reviewController() throws -> MemoryReviewController {
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
