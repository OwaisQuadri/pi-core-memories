import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

private func retainedNativeReviewSave(
  _ fixture: TransactionFixture, isDecisionOnly: Bool = false
) async throws -> (url: URL, draft: MemoryDraft, rootBytes: Data) {
  try fixture.write(
    "# Memory\n\n" + fact("Existing mutable memory."),
    file: fixture.memory.appendingPathComponent("MEMORY.md"))
  _ = try Git(repo: fixture.memory, environment: [:]).data(["add", "MEMORY.md"])
  try fixture.advance()
  try fixture.populate()
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let workspace = Workspace(configURL: url)
  _ = try await workspace.load()
  let opened = try await workspace.openBatch()
  let candidate = try #require(opened.candidates.first { $0.disposition == .pending })
  if isDecisionOnly {
    _ = try await workspace.batch(.decision(candidate.change.id, .reject))
  } else {
    let shown = try #require(
      try await workspace.batch(.acceptance(candidate.change.id)).presentation)
    _ = try await workspace.batch(.stage(shown))
  }
  let draft = try await workspace.persistBatch().draft
  let result = try await workspace.saveBatch()
  switch result {
  case .saved: #expect(!isDecisionOnly)
  case .decisionsSaved: #expect(isDecisionOnly)
  default: throw MemoryError("Expected a checked synthetic Save")
  }
  _ = await workspace.closeBatch()
  let root = fixture.state.appendingPathComponent("root.json")
  let bytes = try Data(contentsOf: root)
  try FileManager.default.removeItem(at: root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  return (url, draft, bytes)
}

@Test @MainActor func nativeSaveDoesNotLoseInputDeliveredDuringFinalPersistence() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let retained = try await retainedNativeReviewSave(fixture)
  let control = NativePersistenceControl()
  let model = AppModel(
    configURL: retained.url, autosaveDelay: .seconds(3600),
    persistence: NativeBatchPersistence(write: control.write))
  await model.load()
  await model.pauseQueue()
  await model.startIndependentManualBatch()
  await model.add()
  let initialRequestCount = await control.requests.count
  await control.pauseWrites()
  let owner = try #require(model.editorOwner)
  model.setEditorText(fact("Initial input before final persistence."), owner: owner)
  model.setEditorReason("Initial reason", owner: owner)
  let save = Task { await model.save() }
  let completion = Task {
    await save.value
    await control.pauseOperationCompleted()
  }
  let newerText = fact("Newer exact input delivered during final persistence.")
  let newerReason = "Newer exact reason"
  do {
    let isHeld = await control.isWritePaused(after: initialRequestCount)
    try #require(isHeld)
    try #require(await control.requests.count == initialRequestCount + 1)
    try #require(model.isBusy)
    model.setEditorText(newerText, owner: owner)
    model.setEditorReason(newerReason, owner: owner)
    await model.stageEditor()
    #expect(model.isBusy, "Stage Edit must not compete with final Save")
    await control.resumeWrites()
    await save.value
    await completion.value
  } catch {
    await control.resumeWrites()
    await save.value
    await completion.value
    throw error
  }
  guard case .saved(let receipt) = model.saveOutcome, let commit = receipt.commit else {
    throw MemoryError("Expected actual independent manual publication")
  }
  #expect(commit == (try fixture.main()))
  let published = try MemoryStore(repo: fixture.memory).reviewSnapshot(base: commit)
  let isNewerPublished = published.reviewEntries().contains {
    $0.entry.bytes.range(of: Data("Newer exact input delivered during final persistence.".utf8))
      != nil
  }
  let manifest = try MemoryBatchReplay.read(
    commit, git: Git(repo: fixture.memory, environment: [:]))
  let isNewerSubmitted =
    manifest.draft.batch?.items.contains { item in
      guard case .manual(let intent) = item.intent else { return false }
      return intent.request.replacement == newerText && intent.request.reason == newerReason
    } == true
  let isNewerRetained =
    model.isInputDirty && model.editorText == newerText && model.editorReason == newerReason
  #expect(
    (isNewerPublished && isNewerSubmitted) || isNewerRetained,
    "Input delivered during final persistence must be published exactly or retained for Discard")
  if isNewerPublished && isNewerSubmitted {
    let revision = model.inputRevision
    model.setEditorText(newerText, owner: owner)
    model.setEditorReason(newerReason, owner: owner)
    #expect(model.inputRevision == revision)
    #expect(!model.isInputDirty)
    #expect(model.editorText.isEmpty)
    #expect(model.editorReason.isEmpty)
    #expect(model.autosaveTask == nil)
    let lateText = fact("Late exact text from the consumed editor.")
    model.setEditorText(lateText, owner: owner)
    model.setEditorReason("Late exact reason", owner: owner)
    #expect(model.isRetainingConsumedInput)
    #expect(model.editorText == lateText)
    #expect(model.editorReason == "Late exact reason")
    #expect(model.isDiscardEnabled)
    #expect(model.autosaveTask == nil)
    await model.discard()
    #expect(!model.isInputDirty)
    #expect(try fixture.main() == commit)
  }
  if isNewerRetained {
    #expect(model.isDiscardEnabled)
    await model.discard()
    #expect(!model.isInputDirty)
    #expect(model.editorText.isEmpty)
    #expect(model.editorReason.isEmpty)
    #expect(try fixture.main() == commit)
  }
  try await model.shutdown()
}
