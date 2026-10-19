import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@Test(arguments: [false, true])
@MainActor func nativeOpeningRecoversInterruptedLegacySaveBeforeAdoption(isMainAdvanced: Bool)
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let store = try MemoryDraftStore(
    repository: fixture.memory, journal: URL(fileURLWithPath: configuration.journal))
  var legacy = try store.create()
  legacy = try store.update(
    draftID: legacy.draftID, expectedRevision: legacy.revision,
    operations: [
      MemoryManagementRequest(
        operation: .add, base: legacy.baseCommit, path: "MEMORY.md",
        replacement: fact("Interrupted legacy Save."), reason: "Requested addition")
    ])
  let key = "native-save-\(legacy.revision)"
  store.afterPublication = { throw DreamRunError.persistenceFailure }
  #expect(throws: (any Error).self) {
    try store.save(draftID: legacy.draftID, expectedRevision: legacy.revision, idempotencyKey: key)
  }
  let published = try fixture.main()
  let receipt = try store.save(
    draftID: legacy.draftID, expectedRevision: legacy.revision, idempotencyKey: key)
  #expect(receipt.commit == published)
  if isMainAdvanced {
    _ = try manager.execute(
      MemoryManagementRequest(
        operation: .add, base: published, path: "MEMORY.md",
        replacement: fact("Later approved work."), reason: "Requested addition"))
  }
  let before = try fixture.main()
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  #expect(model.failure == nil)
  #expect(model.batchProjection != nil)
  #expect(model.draft?.draftID != legacy.draftID)
  #expect(model.stagedItems.isEmpty)
  #expect(try store.list().allSatisfy { $0.draftID != legacy.draftID })
  #expect(try fixture.main() == before)
  #expect(
    try Git(repo: fixture.memory, environment: [:]).text(["rev-parse", receipt.auditRef])
      == published)
  try await model.shutdown()
}

@Test @MainActor func nativeOpeningNeverPublishesAnUnpublishedLegacyDraft() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let store = try MemoryDraftStore(
    repository: fixture.memory, journal: URL(fileURLWithPath: configuration.journal))
  let base = try fixture.main()
  let legacy = try store.create(operations: [
    MemoryManagementRequest(
      operation: .add, base: base, path: "MEMORY.md",
      replacement: fact("Unpublished legacy intent."), reason: "Requested addition")
  ])
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  #expect(model.failure == nil)
  #expect(model.draft?.draftID == legacy.draftID)
  #expect(model.stagedItems.count == 1)
  #expect(try fixture.main() == base)
  #expect(
    try Git(repo: fixture.memory, environment: [:]).text([
      "for-each-ref", "refs/memory-management/drafts/",
    ]).isEmpty)
  #expect(try store.read(legacy.draftID, revision: legacy.revision).schemaVersion == 1)
  try await model.shutdown()
}

@Test(arguments: ["malformed", "unavailable"])
@MainActor func nativeManualDraftRestoresAndSavesWithoutDreamInfrastructure(_ variant: String)
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionNotes($0) }))
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  await model.add()
  model.editorText = fact("Manual intent survives unavailable suggestions.")
  model.editorReason = "Requested addition"
  model.editorChanged()
  try await model.shutdown()
  let original = try #require(model.draft)
  let root = fixture.state.appendingPathComponent("root.json")
  try FileManager.default.removeItem(at: root)
  if variant == "malformed" {
    try fixture.write("{", file: root)
  } else {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }
  let badState = try fixture.snapshot(fixture.state)
  let base = try fixture.main()
  let reopened = AppModel(configURL: url)
  reopened.section = "Memories"
  await reopened.load()
  await reopened.pauseQueue()
  try #require(reopened.batchProjection != nil)
  #expect(reopened.reviewFailure != nil)
  #expect(reopened.draft?.draftID == original.draftID)
  #expect(
    try memoryBatchDigest(reopened.draft?.batch?.binding)
      == memoryBatchDigest(original.batch?.binding))
  await reopened.selectMemory(.staged(try #require(reopened.stagedItems.first).itemID))
  reopened.editorText = fact("Edited manual intent without suggestions.")
  reopened.editorReason = "Requested correction"
  reopened.editorChanged()
  await reopened.add()
  reopened.editorText = fact("New manual intent with unavailable suggestions.")
  reopened.editorReason = "Requested addition"
  reopened.editorChanged()
  await reopened.save()
  #expect(reopened.message == "Saved changes in one commit")
  #expect(reopened.stagedItems.isEmpty)
  let main = try fixture.main()
  #expect(
    try Git(repo: fixture.memory, environment: [:]).text([
      "rev-list", "--count", base + ".." + main,
    ]) == "1")
  #expect(
    try manager.execute(.init(operation: .list)).entries.contains {
      $0.expected.contains("Edited manual intent")
    })
  #expect(try fixture.snapshot(fixture.state) == badState)
  try await reopened.shutdown()
}

@Test @MainActor func nativeUnavailableDreamStateRetainsAndBlocksTheEntireMixedDraft() async throws
{
  let fixture = try ReviewFlowFixture()
  defer { fixture.transaction.clean() }
  let model = AppModel(configURL: fixture.configurationURL)
  model.section = "Memories"
  await model.load()
  let candidate = try #require(model.actionableCandidates.first)
  await model.selectMemory(.candidate(candidate.change.id.rawValue))
  await model.stageShown()
  await model.add()
  model.editorText = fact("Never save only this manual subset.")
  model.editorReason = "Requested addition"
  model.editorChanged()
  try await model.shutdown()
  let draft = try #require(model.draft)
  let base = try fixture.transaction.main()
  try fixture.transaction.write(
    "{", file: fixture.transaction.state.appendingPathComponent("root.json"))
  let before = try fixture.transaction.snapshot(fixture.transaction.state)
  let reopened = AppModel(configURL: fixture.configurationURL)
  reopened.section = "Memories"
  await reopened.load()
  await reopened.pauseQueue()
  #expect(reopened.batchProjection == nil)
  #expect(reopened.failure != nil)
  #expect(reopened.stagedItems.count == 2)
  #expect(try memoryBatchDigest(reopened.draft) == memoryBatchDigest(draft))
  #expect(!reopened.isSaveEnabled)
  await reopened.save()
  await reopened.recoverSave()
  #expect(try memoryBatchDigest(reopened.draft) == memoryBatchDigest(draft))
  #expect(try fixture.transaction.main() == base)
  #expect(try fixture.transaction.snapshot(fixture.transaction.state) == before)
  try await reopened.shutdown()
}

@Test @MainActor func nativeSupported257DocumentStoreOpensRestoresAndSavesOneEdit() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.write(
    "# Memory\n\n" + fact("Global preference."),
    file: fixture.memory.appendingPathComponent("MEMORY.md"))
  var paths = ["MEMORY.md"]
  for index in 0..<256 {
    let path = "devices/" + String(format: "%064x", index) + "/MEMORY.md"
    paths.append(path)
    try fixture.write(
      "# Memory\n\n" + fact("Device preference \(index)."),
      file: fixture.memory.appendingPathComponent(path))
  }
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "."])
  try fixture.advance()
  let base = try fixture.main()
  #expect(try MemoryStore(repo: fixture.memory).reviewSnapshot(base: base).documents.count == 257)
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let manager = try MemoryManagement(repository: fixture.memory)
  try manager.confirmDetach(manager.checkoutPreview())
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  await model.pauseQueue()
  try #require(model.batchProjection != nil)
  #expect(model.draft?.batch?.binding.allowedPaths == paths.sorted())
  #expect(model.batchProjection?.entries.count == 64)
  let entry = try #require(model.visibleEntries.first { $0.path == "MEMORY.md" })
  await model.selectMemory(.entry(entry.path, entry.locator.start))
  model.editorText = fact("Corrected global preference.")
  model.editorReason = "Requested correction"
  model.editorChanged()
  try await model.shutdown()
  let original = try #require(model.draft)
  let reopened = AppModel(configURL: url)
  reopened.section = "Memories"
  await reopened.load()
  await reopened.pauseQueue()
  #expect(reopened.stagedItems.count == 1)
  #expect(
    try memoryBatchDigest(reopened.draft?.batch?.binding)
      == memoryBatchDigest(original.batch?.binding))
  await reopened.save()
  #expect(reopened.failure == nil)
  #expect(reopened.message == "Saved changes in one commit")
  #expect(try git.text(["rev-list", "--count", base + ".." + fixture.main()]) == "1")
  #expect(
    try manager.execute(.init(operation: .list)).entries.contains {
      $0.path == "MEMORY.md" && $0.expected.contains("Corrected global")
    })
  try await reopened.shutdown()
}
