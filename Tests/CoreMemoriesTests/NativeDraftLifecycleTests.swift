import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@MainActor func pendingNativeModel(
  _ fixture: TransactionFixture, persistence: NativeBatchPersistence = NativeBatchPersistence()
) async throws -> AppModel {
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url, autosaveDelay: .seconds(3600), persistence: persistence)
  await model.load()
  _ = try #require(model.catalog)
  await model.add()
  model.editorText = "Retain this synthetic draft. [source: fixture; added: 2026-10-17]"
  model.editorReason = "Synthetic edit"
  model.editorChanged()
  #expect(model.isInputDirty)
  return model
}

@Test @MainActor func nativeDraftFinalRemovalIsFlushedBeforeQuitAndDoesNotReturn() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  try await model.shutdown()
  await model.removeItem(try #require(model.stagedItems.first).itemID)
  try await model.shutdown()
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  #expect(reopened.stagedItems.isEmpty)
  #expect(reopened.draft?.batch?.items.isEmpty == true)
  #expect(!model.isDraftDirty)
  try await reopened.shutdown()
}

@Test @MainActor func nativeDraftStaleFirstAutosavePreservesEditsThroughRefreshAndRelaunch()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  let base = try fixture.main()
  try fixture.advance()
  let advanced = try fixture.main()
  await model.refresh()
  #expect(model.stagedItems.count == 1)
  #expect(model.draft?.baseCommit == base)
  try await model.shutdown()
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  #expect(reopened.stagedItems.count == 1)
  #expect(reopened.draft?.baseCommit == base)
  await reopened.loadCandidates()
  #expect(reopened.failure != nil)
  #expect(reopened.stagedItems.count == 1)
  await reopened.save()
  #expect(reopened.stagedItems.count == 1)
  #expect(try fixture.main() == advanced)
  try await reopened.shutdown()
}
