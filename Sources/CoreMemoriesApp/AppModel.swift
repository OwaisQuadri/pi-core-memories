import AppKit
import CoreMemories
import Foundation

@MainActor final class AppModel: ObservableObject {
  @Published var section = "Dreams"
  @Published var configuration = MemoryConfiguration.defaults
  @Published var catalog: MemoryManagementResult?
  @Published var drafts: [MemoryDraft] = []
  @Published var inspection: DreamInspection?
  @Published var candidates: [MemoryReviewCandidate] = []
  @Published var preview: MemoryReviewPreview?
  @Published var draft: MemoryDraft?
  @Published var operations: [MemoryManagementRequest] = []
  @Published var message = ""
  @Published var failure: String?
  @Published var isBusy = false
  @Published var isDreamRunning = false
  @Published var dreamPhase = "Idle"
  @Published var dreamDetail = ""
  private var terminalPhase: String?
  private var isCancellingDream = false
  @Published var resolvedSelection = "Not resolved"
  @Published var dreamEvents: [String] = []
  @Published var artifactText = ""
  @Published var selectedArtifact: DreamArtifact?
  @Published var editorText = ""
  @Published var editorReason = ""
  @Published var editorPath = "MEMORY.md"
  @Published var isEditing = false
  @Published var isShowingAllDevices = false
  @Published var checkout: MemoryReviewCheckoutPreview?
  @Published var isConfirmingReplacement = false
  @Published var isConfirmingRetry = false
  @Published var isConfirmingDiscard = false
  private var editorTarget: ManagedMemoryEntry?
  private var editorIndex: Int?
  private var isLoadingEditor = false
  private var autosaveTask: Task<Void, Never>?
  private var shutdownTask: Task<Void, Error>?
  private var editRevision: UInt64 = 0
  private var persistedEditRevision: UInt64 = 0
  private var dreamTask: Task<Void, Never>?
  private var control: DreamControl?
  let workspace: Workspace
  let configURL: URL

  init(configURL: URL) {
    self.configURL = configURL
    self.workspace = Workspace(configURL: configURL)

  }

  var isExistingEntry: Bool { editorTarget != nil }
  var isDraftDirty: Bool { editRevision != persistedEditRevision }

  var visibleEntries: [ManagedMemoryEntry] {
    (catalog?.entries ?? []).filter { row in
      guard MemoryDocument.isMemoryContent(Data(row.expected.utf8)) else { return false }
      return isShowingAllDevices || !row.path.hasPrefix("devices/")
        || configuration.deviceKey.map { row.path.hasPrefix("devices/\($0)/") } == true
    }
  }

  func load() async {
    do { apply(try await workspace.load()) } catch { failure = String(describing: error) }
  }

  func refresh() async { apply(await workspace.refresh()) }

  private func apply(_ snapshot: WorkspaceSnapshot) {
    configuration = snapshot.configuration
    catalog = snapshot.catalog
    inspection = snapshot.inspection
    drafts = snapshot.drafts
    if draft == nil, !isDraftDirty, operations.isEmpty, let recovered = drafts.last {
      draft = recovered
      operations = recovered.operations
      message = "Recovered draft · revision \(recovered.revision)"
    }
    if !snapshot.failures.isEmpty { failure = snapshot.failures.joined(separator: "\n") }
  }

  func edit(_ entry: ManagedMemoryEntry) {
    guard !isBusy else { return }
    guard entry.isMutable else {
      failure = entry.limitation
      return
    }
    isLoadingEditor = true
    editorTarget = entry
    editorIndex = operations.firstIndex {
      $0.path == entry.path && $0.locator == entry.locator && $0.operation != .add
    }
    editorPath = entry.path
    editorReason = editorIndex.map { operations[$0].reason ?? "" } ?? ""
    do {
      editorText =
        try editorIndex.map { operations[$0].replacement ?? entry.expected }
        ?? MemoryDocument.editableEntry(Data(entry.expected.utf8))
    } catch { failure = String(describing: error) }
    isEditing = true
    isLoadingEditor = false
  }

  func add(path: String = "MEMORY.md") {
    guard !isBusy else { return }
    isLoadingEditor = true
    editorTarget = nil
    editorIndex = nil
    editorPath = path
    editorReason = ""
    editorText = ""
    isEditing = true
    section = "Memories"
    isLoadingEditor = false
  }

  func addProject(isDeviceSpecific: Bool) async {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Project"
    guard panel.runModal() == .OK, let directory = panel.url else { return }
    let bindings = configuration.projectBindings
    do {
      guard
        let key = try await Task.detached(operation: {
          try MemoryStore.projectKey(cwd: directory, projectBindings: bindings)
        }).value
      else { throw WorkspaceError("choose a Git project directory") }
      if isDeviceSpecific {
        guard let device = configuration.deviceKey else {
          throw WorkspaceError("set up this device first")
        }
        add(path: "devices/\(device)/projects/\(key).md")
      } else {
        add(path: "projects/\(key).md")
      }
    } catch { failure = String(describing: error) }
  }

  func editOperation(_ index: Int) {
    guard !isBusy, operations.indices.contains(index) else { return }
    let operation = operations[index]
    isLoadingEditor = true
    editorIndex = index
    editorTarget = catalog?.entries.first {
      $0.path == operation.path && $0.locator == operation.locator
    }
    editorPath = operation.path ?? "MEMORY.md"
    editorText = operation.replacement ?? operation.expected ?? ""
    editorReason = operation.reason ?? ""
    isEditing = operation.operation != .delete
    isLoadingEditor = false
    section = "Memories"
  }

  func editorChanged() {
    guard isEditing, !isBusy, !isLoadingEditor,
      let base = draft?.baseCommit ?? operations.first?.base ?? catalog?.base
    else {
      return
    }
    let request = MemoryManagementRequest(
      operation: editorTarget == nil ? .add : .update,
      base: base, path: editorPath, locator: editorTarget?.locator,
      expected: editorTarget?.expected,
      replacement: editorText, reason: editorReason)
    if let index = editorIndex, operations.indices.contains(index) {
      operations[index] = request
    } else {
      operations.append(request)
      editorIndex = operations.count - 1
    }
    queueAutosave()
  }

  func deleteEntry() {
    guard !isBusy, let target = editorTarget,
      let base = draft?.baseCommit ?? operations.first?.base ?? catalog?.base
    else { return }
    let operation = MemoryManagementRequest(
      operation: .delete, base: base, path: target.path,
      locator: target.locator, expected: target.expected, reason: editorReason)
    if let index = editorIndex, operations.indices.contains(index) {
      operations[index] = operation
    } else {
      operations.append(operation)
    }
    isEditing = false
    section = "Changes"
    queueAutosave()
  }

  func removeOperation(_ index: Int) {
    guard !isBusy, operations.indices.contains(index) else { return }
    operations.remove(at: index)
    isEditing = false
    editorIndex = nil
    queueAutosave()
  }

  private func queueAutosave() {
    editRevision &+= 1
    let previous = autosaveTask
    previous?.cancel()
    message = "Draft not yet persisted"
    autosaveTask = Task {
      await previous?.value
      do {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()
        try await persistEditor()
      } catch is CancellationError {} catch { failure = String(describing: error) }
    }
  }

  private func persistEditor() async throws {
    guard let base = draft?.baseCommit ?? operations.first?.base ?? catalog?.base else {
      throw WorkspaceError("approved catalog is unavailable")
    }
    let revision = editRevision
    draft = try await workspace.autosave(operations, base: base)
    persistedEditRevision = revision
    message = "Draft saved locally · revision \(draft?.revision ?? 0)"
  }

  func save() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    autosaveTask?.cancel()
    await autosaveTask?.value
    do {
      try await persistEditor()
      let receipt = try await workspace.save()
      operations = []
      persistedEditRevision = editRevision
      draft = nil
      isEditing = false
      message = "Saved one commit · \(receipt.commit)"
      await refresh()
    } catch { failure = String(describing: error) }
  }

  func discard() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    autosaveTask?.cancel()
    await autosaveTask?.value
    do {
      try await workspace.discard()
      operations = []
      persistedEditRevision = editRevision
      draft = nil
      isEditing = false
      message = "Draft discarded"
      await refresh()
    } catch { failure = String(describing: error) }
  }

  func restore(_ value: MemoryDraft) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    autosaveTask?.cancel()
    await autosaveTask?.value
    do {
      if isDraftDirty { try await persistEditor() }
      try await workspace.restore(value)
      draft = value
      operations = value.operations
      persistedEditRevision = editRevision
      isEditing = false
      message = "Recovered draft · revision \(value.revision)"
    } catch { failure = String(describing: error) }
  }

  func prepareCheckout() async {
    do { checkout = try await workspace.checkoutPreview() } catch {
      failure = String(describing: error)
    }
  }

  func detach() async {
    guard let checkout else { return }
    do {
      try await workspace.detach(checkout)
      self.checkout = nil
      message = "Checkout prepared; no memory was approved"
    } catch { failure = String(describing: error) }
  }

  func loadCandidates() async {
    do { candidates = try await workspace.candidates() } catch {
      failure = String(describing: error)
    }
  }

  func showPreview(_ candidate: MemoryReviewCandidate) async {
    preview = nil
    do { preview = try await workspace.preview(candidate.change.id) } catch {
      failure = String(describing: error)
    }
  }

  func approve() async {
    guard let shown = preview else { return }
    preview = nil
    do {
      let receipt = try await workspace.approve(shown)
      message = "Approved entry · \(receipt.commit)"
      await loadCandidates()
      await refresh()
    } catch { failure = String(describing: error) }
  }

  func disposition(_ candidate: MemoryReviewCandidate, isRejected: Bool) async {
    preview = nil
    do {
      try await workspace.disposition(candidate.change.id, isRejected: isRejected)
      await loadCandidates()
    } catch { failure = String(describing: error) }
  }

  func confirmReviewed(_ entry: ManagedMemoryEntry) async {
    guard let base = catalog?.base else { return }
    do {
      try await workspace.confirmReviewed(entry, base: base)
      await refresh()
    } catch { failure = String(describing: error) }
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
    guard !isBusy, !isDreamRunning else { return }
    isDreamRunning = true
    dreamPhase = "Starting"
    dreamDetail = ""
    terminalPhase = nil
    isCancellingDream = false
    dreamEvents = []
    resolvedSelection = "Not resolved"
    let control = DreamControl()
    self.control = control
    let config = configuration
    dreamTask = Task {
      let events = AsyncStream<Data>.makeStream()
      let consumer = Task {
        for await bytes in events.stream { receive(bytes) }
      }
      do {
        try await Task.detached {
          defer { events.continuation.finish() }
          try control.run(
            operation: operation, settings: config.settings, roots: config.roots,
            diagnostics: URL(fileURLWithPath: config.diagnostics), deviceKey: config.deviceKey,
            projectBindings: config.projectBindings, onEvent: { events.continuation.yield($0) })
        }.value
        await consumer.value
        dreamPhase = terminalPhase ?? "Finished"
      } catch {
        await consumer.value
        dreamPhase = isCancellingDream ? "Cancelled" : "Stopped"
        if !isCancellingDream { failure = String(describing: error) }
      }
      isDreamRunning = false
      self.control = nil
      await refresh()
    }
  }

  private func receive(_ bytes: Data) {
    guard let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      return
    }
    if let selection = event["selection"] as? [String: Any] {
      resolvedSelection = [selection["provider"], selection["modelID"], selection["thinkingLevel"]]
        .map { $0 as? String ?? "unknown" }.joined(separator: " / ")
    }
    if let phase = event["phase"] as? String { dreamPhase = phase }
    if event["event"] as? String == "report", let report = event["report"] as? [String: Any],
      let status = report["status"] as? String
    {
      terminalPhase =
        isCancellingDream && report["reason"] as? String == "callInterrupted"
        ? "Cancelled" : status == "noNewRecords" ? "No new records" : status.capitalized
      dreamDetail = report["detail"] as? String ?? report["reason"] as? String ?? ""
    }
    let formatted =
      (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .prettyPrinted]))
      ?? bytes
    dreamEvents.append(String(decoding: formatted, as: UTF8.self))
    if dreamEvents.count > 200 { dreamEvents.removeFirst() }
  }

  func cancelDream() {
    guard isDreamRunning, terminalPhase == nil else { return }
    isCancellingDream = true
    dreamPhase = "Cancelling"
    control?.cancel()
  }

  func saveSettings(isSettingUpDevice: Bool = false) async {
    do {
      guard !isBusy, !isDraftDirty, operations.isEmpty else {
        throw WorkspaceError("Save or discard local edits before changing configuration")
      }
      var value = configuration
      if isSettingUpDevice { value.setupDevice() }
      try await workspace.configure(value)
      configuration = value
      message = "Settings saved"
      await refresh()
    } catch { failure = String(describing: error) }
  }

  func shutdown() async throws {
    if let shutdownTask {
      try await shutdownTask.value
      return
    }
    guard !isBusy else { throw WorkspaceError("Wait for the current operation before quitting") }
    isBusy = true
    let task = Task<Void, Error> {
      autosaveTask?.cancel()
      await autosaveTask?.value
      if isDraftDirty { try await persistEditor() }
      control?.cancel()
      await dreamTask?.value
    }
    shutdownTask = task
    defer {
      shutdownTask = nil
      isBusy = false
    }
    try await task.value
  }
}
