import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

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
