import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@MainActor private func pendingNativeModel(_ fixture: TransactionFixture) async throws -> AppModel {
  var configuration = MemoryConfiguration.defaults
  configuration.roots = DreamControlRoots(
    state: fixture.state.path, sessions: fixture.sessions.path, memory: fixture.memory.path,
    snippets: fixture.snippets.path, prompts: nil, globalAgents: nil)
  configuration.journal = fixture.root.appendingPathComponent("journal").path
  configuration.reviewState = fixture.root.appendingPathComponent("review").path
  configuration.diagnostics = fixture.root.appendingPathComponent("diagnostics").path
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url, autosaveDelay: .seconds(3600))
  await model.load()
  _ = try #require(model.catalog)
  model.add()
  model.editorText = "Retain this synthetic draft. [source: fixture; added: 2026-10-17]"
  model.editorReason = "Synthetic edit"
  model.editorChanged()
  #expect(model.operations.count == 1)
  return model
}

@Test(arguments: ["missing", "corrupt"])
@MainActor func nativeActionsStayBlockedUntilTheSelectedProfileLoads(_ variant: String) async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let url = fixture.root.appendingPathComponent("selected.json")
  if variant == "corrupt" { try fixture.write("{", file: url) }
  let model = AppModel(configURL: url)
  #expect(model.isBusy)
  model.add()
  #expect(!model.isEditing)
  await model.load()
  #expect(model.failure != nil)
  #expect(model.isBusy)
  model.add()
  #expect(!model.isEditing)
  #expect(model.catalog == nil)
  let delegate = ApplicationDelegate()
  delegate.model = model
  #expect(await delegate.isTerminationReady())
}

@Test @MainActor func nativeDraftFinalRemovalIsFlushedBeforeQuitAndDoesNotReturn() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  try await model.shutdown()
  model.removeOperation(0)
  try await model.shutdown()
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  #expect(reopened.operations.isEmpty)
  #expect(reopened.draft?.operations.isEmpty == true)
  #expect(!model.isDraftDirty)
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
  #expect(model.operations.count == 1)
  #expect(model.operations.first?.base == base)
  try await model.shutdown()
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  #expect(reopened.operations.count == 1)
  #expect(reopened.draft?.baseCommit == base)
  await reopened.save()
  #expect(reopened.failure != nil)
  #expect(reopened.operations.count == 1)
  #expect(try fixture.main() == advanced)
}

@Test @MainActor func nativeTerminationRefusesFailedDraftFlushAndCanRetry() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  let journal = URL(fileURLWithPath: model.configuration.journal)
  try Data("Blocked journal".utf8).write(to: journal)
  let delegate = ApplicationDelegate()
  delegate.model = model
  #expect(await delegate.isTerminationReady() == false)
  #expect(model.failure != nil)
  #expect(model.operations.count == 1)
  #expect(model.isDraftDirty)
  #expect(!model.isBusy)
  try FileManager.default.removeItem(at: journal)
  #expect(await delegate.isTerminationReady())
  #expect(!model.isDraftDirty)
}

@Test @MainActor func nativeSettingsCannotRedirectAnEditDuringInitialDebounce() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let model = try await pendingNativeModel(fixture)
  let other = fixture.root.appendingPathComponent("other-memory")
  try FileManager.default.copyItem(at: fixture.memory, to: other)
  #expect(try MemoryStore(repo: other, environment: [:]).approvedCommit() == fixture.main())
  model.configuration.roots?.memory = other.path
  model.configuration.journal = fixture.root.appendingPathComponent("other-journal").path
  await model.saveSettings()
  #expect(model.failure?.contains("Save or discard local edits") == true)
  #expect(try MemoryConfiguration.load(from: model.configURL).memoryURL.path == fixture.memory.path)
  try await model.shutdown()
  let reopened = AppModel(configURL: model.configURL)
  await reopened.load()
  #expect(reopened.operations.count == 1)
  #expect(reopened.configuration.memoryURL.path == fixture.memory.path)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.root.appendingPathComponent("other-journal").path))
}
