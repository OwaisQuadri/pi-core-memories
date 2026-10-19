import AppKit
import CoreMemories
import Foundation

@MainActor final class AppModel: ObservableObject {
  @Published var section = "Dreams"
  @Published var configuration = MemoryConfiguration.defaults {
    didSet { savedRecovery = nil }
  }
  @Published var catalog: MemoryManagementResult?
  @Published var drafts: [MemoryDraft] = []
  @Published var draftRecoveries: [MemoryDraftRecovery] = []
  @Published var draftRecoveryDetails: MemoryDraft?
  @Published var isConfirmingIndependentManual = false
  @Published var inspection: DreamInspection?
  @Published var dreamInspectionFailure: String?
  @Published var batchProjection: MemoryBatchProjection?
  @Published var postSaveCandidates: [MemoryReviewCandidate] = []
  @Published var presentation: MemoryBatchPresentation?
  @Published var selection: NativeMemorySelection?
  @Published var retainedDraft: MemoryDraft?
  @Published var saveOutcome: MemoryBatchSaveResult?
  @Published var editorTarget: NativeEditorTarget?
  @Published var editorText = ""
  @Published var editorReason = ""
  @Published var editorPath = "MEMORY.md"
  @Published var isShowingDiff = false
  @Published var isShowingAllDevices = false
  @Published var isInputDirty = false
  @Published var inputRevision: UInt64 = 0
  @Published var savedRecovery: SavedRecoveryPresentation?
  @Published var message = ""
  @Published var failure: String?
  @Published var draftFailure: String?
  @Published var isBusy = true
  @Published var isDreamRunning = false
  @Published var dreamPhase = "Idle"
  @Published var dreamDetail = ""
  @Published var queueSnapshot: DreamQueueSnapshot?
  @Published var isQueueLoading = false
  @Published var isReviewLoading = false
  @Published var reviewFailure: String?
  @Published var eventCoverage: DreamQueueCoverage?
  @Published var coverageObservedAt: Date?
  @Published var invocationStatus: DreamInvocationStatus?
  @Published var resolvedSelection = "Not resolved"
  @Published var dreamEvents: [String] = []
  @Published var artifactText = ""
  @Published var selectedArtifact: DreamArtifact?
  @Published var checkout: MemoryReviewCheckoutPreview?
  @Published var isConfirmingReplacement = false
  @Published var isConfirmingRetry = false
  @Published var isConfirmingDiscard = false
  var stagedInputRevision: UInt64 = 0
  var persistedBatchRevision: UInt64?
  var workspaceGeneration: UInt64 = 0
  var autosaveTask: Task<Void, Never>?
  var autosaveID: UUID?
  var submittedInput: NativeSubmittedInput?
  var isSubmittingSave = false
  var isWorkspaceLoaded = false
  var isLoaded = false
  private var shutdownTask: Task<Void, Error>?
  private var queueTask: Task<Void, Never>?
  private var queueRevision: UInt64 = 0
  private(set) var queueScanCount = 0
  private var terminalPhase: String?
  private var isCancellingDream = false
  private var dreamTask: Task<Void, Never>?
  private var control: DreamControl?
  let workspace: Workspace
  let configURL: URL
  let autosaveDelay: Duration

  init(
    configURL: URL, autosaveDelay: Duration = .milliseconds(500),
    persistence: NativeBatchPersistence = NativeBatchPersistence()
  ) {
    self.configURL = configURL
    self.autosaveDelay = autosaveDelay
    self.workspace = Workspace(configURL: configURL, persistence: persistence)
  }

  func load() async {
    guard !isLoaded else { return }
    do {
      apply(try await workspace.load())
      isLoaded = true
      isBusy = false
      if section == "Memories" { await loadCandidates() }
      reloadQueue()
    } catch { failure = String(describing: error) }
  }

  func refresh() async {
    guard isLoaded, !isBusy, !isDreamRunning, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      if !isRetainingConsumedInput { try await flushInputAndPersistence() }
      await refreshSnapshot()
    } catch { failure = String(describing: error) }
  }

  func refreshSnapshot(isRepreparingBatch: Bool = true) async {
    postSaveCandidates = []
    await pauseQueue()
    savedRecovery = nil
    apply(await workspace.refresh())
    if !isRepreparingBatch || isWaitingForIndependentManualWork || isRetainingConsumedInput
      || isSubmittingSave
    {
      isWorkspaceLoaded = false
      reviewFailure = await workspace.reviewPreparationFailure
    } else if isWorkspaceLoaded || section == "Memories" {
      if isSubmittedOwnerConsumed { submittedInput = nil }
      workspaceGeneration &+= 1
      do {
        let prepared = try await workspace.reprepareBatch()
        clearEditor()
        applyBatch(prepared)
        draftRecoveries = await workspace.draftRecoveries
        reviewFailure = await workspace.reviewPreparationFailure
      } catch {
        failure = String(describing: error)
      }
    }
    if batchProjection == nil {
      let readback = await workspace.reviewCandidatePage()
      postSaveCandidates = readback.candidates
      reviewFailure = readback.failure
      isWorkspaceLoaded = false
    }
    reloadQueue()
  }

  var resumableRun: SavedDreamRun? {
    inspection?.runs.first(where: { !$0.isCompleted && $0.attempts.last?.status == "Reply valid" })
  }

  var savedRecoveryRunID: String? {
    guard let run = resumableRun, let base = catalog?.base,
      let approvedBase = run.approvedBase, approvedBase != base,
      let count = run.attempts.last?.suggestionCount, count > 0
    else { return nil }
    return run.id
  }

  func prepareSavedRecovery() async {
    guard isLoaded, !isBusy, !isDreamRunning, !isSaveUnresolved,
      let runID = savedRecoveryRunID, let base = catalog?.base
    else { return }
    isBusy = true
    defer { isBusy = false }
    savedRecovery = nil
    presentation = nil
    await pauseQueue()
    do {
      try await flushInputAndPersistence()
      let prepared = try await workspace.prepareSavedRecovery(
        runID: runID, profile: configuration, base: base)
      isBusy = false
      savedRecovery = prepared
    } catch { failure = String(describing: error) }
  }

  func cancelSavedRecovery() async {
    guard !isBusy else { return }
    savedRecovery = nil
    await workspace.cancelSavedRecovery()
  }

  func confirmSavedRecovery() async {
    guard isLoaded, !isBusy, !isDreamRunning, savedRecovery != nil,
      let base = catalog?.base
    else { return }
    isBusy = true
    defer { isBusy = false }
    savedRecovery = nil
    presentation = nil
    do {
      try await flushInputAndPersistence()
      try await workspace.confirmSavedRecovery(profile: configuration, base: base)
      section = "Memories"
      invocationStatus = nil
      dreamPhase = "Ready to review"
      dreamDetail = ""
      message = "Saved suggestions prepared. No model call or memory approval."
      await refreshSnapshot()
    } catch { failure = String(describing: error) }
  }

  func pauseQueue() async {
    queueTask?.cancel()
    await queueTask?.value
  }

  private func reloadQueue() {
    queueScanCount += 1
    queueTask?.cancel()
    queueRevision &+= 1
    let revision = queueRevision
    let configuration = configuration
    isQueueLoading = true
    let scan = Task.detached { DreamQueueSnapshot.read(configuration: configuration) }
    queueTask = Task {
      let snapshot = await withTaskCancellationHandler {
        await scan.value
      } onCancel: {
        scan.cancel()
      }
      guard revision == queueRevision else { return }
      isQueueLoading = false
      if !Task.isCancelled { queueSnapshot = snapshot }
    }
  }

  private func apply(_ snapshot: WorkspaceSnapshot) {
    configuration = snapshot.configuration
    catalog = snapshot.catalog
    inspection = snapshot.inspection
    dreamInspectionFailure = snapshot.dreamInspectionFailure
    if !isDreamRunning {
      if let unavailable = snapshot.invocationStatusFailure {
        invocationStatus = nil
        dreamPhase = "Status unavailable"
        dreamDetail = unavailable
      } else if let status = snapshot.invocationStatus {
        applyStatus(status)
      } else if invocationStatus != nil || dreamPhase == "Status unavailable" {
        invocationStatus = nil
        dreamPhase = "Idle"
        dreamDetail = ""
      }
    }
    drafts = snapshot.drafts
    draftRecoveries = snapshot.draftRecoveries
    draftRecoveryDetails = nil
    if case .recovery = selection { selection = nil }
    if batchProjection == nil, !isInputDirty, !isSubmittedOwnerConsumed, draftRecoveries.isEmpty,
      let recovered = drafts.last
    {
      retainedDraft = recovered
      message = "Recovered draft"
    }
    if !snapshot.failures.isEmpty { failure = snapshot.failures.joined(separator: "\n") }
  }

  func prepareCheckout() async {
    guard isLoaded, !isBusy, !isDreamRunning, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      await pauseQueue()
      try await flushInputAndPersistence()
      checkout = try await workspace.checkoutPreview()
    } catch { failure = String(describing: error) }
  }

  func detach() async {
    guard isLoaded, !isBusy, !isDreamRunning, let checkout, !isSaveUnresolved else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      await pauseQueue()
      try await flushInputAndPersistence()
      try await workspace.detach(checkout)
      self.checkout = nil
      if isWorkspaceLoaded {
        workspaceGeneration &+= 1
        let prepared = try await workspace.reprepareBatch()
        clearEditor()
        applyBatch(prepared)
      }
      presentation = nil
      message = "Checkout prepared; no memory was approved"
    } catch { failure = String(describing: error) }
  }

  var queueCoverage: DreamQueueCoverage? {
    if let eventCoverage, eventCoverage.segments != nil,
      coverageObservedAt.map({ $0 > (queueSnapshot?.observedAt ?? .distantPast) }) == true
    {
      return eventCoverage
    }
    return queueSnapshot?.coverage ?? eventCoverage
  }

  var queueObservedAt: Date? {
    if let eventCoverage, eventCoverage.segments != nil,
      coverageObservedAt.map({ $0 > (queueSnapshot?.observedAt ?? .distantPast) }) == true
    {
      return coverageObservedAt
    }
    return queueSnapshot?.coverage == nil ? coverageObservedAt : queueSnapshot?.observedAt
  }

  func inspect(_ artifact: DreamArtifact) async {
    selectedArtifact = artifact
    artifactText = "Loading…"
    do { artifactText = try await workspace.artifact(artifact) } catch {
      artifactText = String(describing: error)
    }
  }

  func revealArtifact() async {
    guard let selectedArtifact else { return }
    do {
      NSWorkspace.shared.activateFileViewerSelecting([try await workspace.reveal(selectedArtifact)])
    } catch { failure = String(describing: error) }
  }

  func revealMemory() async {
    do {
      NSWorkspace.shared.activateFileViewerSelecting([
        try await workspace.revealMemory(path: editorPath)
      ])
    } catch { failure = String(describing: error) }
  }

  func run(_ operation: DreamControlOperation) {
    guard isLoaded, !isBusy, !isDreamRunning, !isSaveUnresolved else { return }
    savedRecovery = nil
    isDreamRunning = true
    dreamPhase = "Starting"
    dreamDetail = ""
    invocationStatus = nil
    eventCoverage = nil
    coverageObservedAt = nil
    terminalPhase = nil
    isCancellingDream = false
    dreamEvents = []
    resolvedSelection = "Not resolved"
    let control = DreamControl()
    self.control = control
    let config = configuration
    dreamTask = Task {
      await workspace.cancelSavedRecovery()
      await pauseQueue()
      let events = AsyncStream<Data>.makeStream()
      let consumer = Task { for await bytes in events.stream { receive(bytes) } }
      do {
        try await flushInputAndPersistence()
        try await Task.detached {
          defer { events.continuation.finish() }
          try control.run(
            operation: operation, settings: config.settings, roots: config.roots,
            diagnostics: URL(fileURLWithPath: config.diagnostics), deviceKey: config.deviceKey,
            projectBindings: config.projectBindings, onEvent: { events.continuation.yield($0) })
        }.value
        await consumer.value
        dreamPhase = terminalPhase ?? "Invocation ended; completion not established"
      } catch {
        events.continuation.finish()
        await consumer.value
        dreamPhase = isCancellingDream ? "Cancelled" : "Stopped"
        if !isCancellingDream { failure = String(describing: error) }
      }
      isDreamRunning = false
      self.control = nil
      await refresh()
    }
  }

  func receive(_ bytes: Data) {
    guard let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      return
    }
    if let selection = event["selection"] as? [String: Any] {
      resolvedSelection = [selection["provider"], selection["modelID"], selection["thinkingLevel"]]
        .map { $0 as? String ?? "unknown" }.joined(separator: " / ")
    }
    if let phase = event["phase"] as? String {
      switch phase {
      case "modelCall": dreamPhase = "Model working"
      case "planning": dreamPhase = "Preparing batch"
      case "saving": dreamPhase = "Saving inference"
      default: dreamPhase = phase
      }
    }
    if event["event"] as? String == "progress", let coverage = event["coverage"] as? [String: Any] {
      do {
        eventCoverage = try DreamQueueCoverage(json: coverage)
        coverageObservedAt = Date()
      } catch {
        eventCoverage = nil
        dreamDetail = "Invalid queue progress received; showing the last read-only snapshot."
      }
    }
    if event["event"] as? String == "report", let report = event["report"] as? [String: Any],
      let status = report["status"] as? String
    {
      if let saved = DreamInvocationStatus(report: report) { applyStatus(saved) }
      terminalPhase =
        isCancellingDream && report["reason"] as? String == "callInterrupted"
        ? "Cancelled" : invocationStatus?.title ?? status.capitalized
    }
    let formatted =
      (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .prettyPrinted]))
      ?? bytes
    dreamEvents.append(String(decoding: formatted, as: UTF8.self))
    if dreamEvents.count > 200 { dreamEvents.removeFirst() }
  }

  private func applyStatus(_ status: DreamInvocationStatus) {
    invocationStatus = status
    dreamPhase = status.title
    dreamDetail = status.explanation
  }

  func cancelDream() {
    guard isDreamRunning, terminalPhase == nil else { return }
    isCancellingDream = true
    dreamPhase = "Cancelling"
    control?.cancel()
  }

  func saveSettings(isSettingUpDevice: Bool = false) async {
    do {
      guard isLoaded, !isBusy, !isDreamRunning, !isInputDirty, stagedItems.isEmpty,
        !isSaveUnresolved
      else {
        throw WorkspaceError("Save or discard local edits before changing configuration")
      }
      isBusy = true
      defer { isBusy = false }
      savedRecovery = nil
      var value = configuration
      if isSettingUpDevice { value.setupDevice() }
      await pauseQueue()
      try await flushInputAndPersistence()
      try await workspace.configure(value)
      workspaceGeneration &+= 1
      configuration = value
      clearEditor()
      batchProjection = nil
      retainedDraft = nil
      isWorkspaceLoaded = false
      queueSnapshot = nil
      presentation = nil
      invocationStatus = nil
      eventCoverage = nil
      coverageObservedAt = nil
      dreamPhase = "Idle"
      dreamDetail = ""
      postSaveCandidates = []
      message = "Settings saved"
      await refreshSnapshot()
    } catch { failure = String(describing: error) }
  }

  func shutdown() async throws {
    guard isLoaded else { return }
    if let shutdownTask {
      try await shutdownTask.value
      return
    }
    guard !isBusy else { throw WorkspaceError("Wait for the current operation before quitting") }
    isBusy = true
    savedRecovery = nil
    let task = Task<Void, Error> {
      await workspace.cancelSavedRecovery()
      await pauseQueue()
      try await flushInputAndPersistence()
      guard !isSaveUnresolved else {
        throw WorkspaceError("Resolve the Save outcome before quitting")
      }
      control?.cancel()
      await dreamTask?.value
      queueTask?.cancel()
      await queueTask?.value
      retainedDraft = await workspace.closeBatch()
      workspaceGeneration &+= 1
      batchProjection = nil
      presentation = nil
      draftRecoveryDetails = nil
      isWorkspaceLoaded = false
      postSaveCandidates = []
    }
    shutdownTask = task
    defer {
      shutdownTask = nil
      isBusy = false
    }
    try await task.value
  }
}
