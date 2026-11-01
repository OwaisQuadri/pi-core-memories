import Combine
import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

@Test func nativeReviewPreviewPreservesLiteralSourcesAndStoredBytes() throws {
  let text =
    #"Keep `[source: literal; added: 2026-01-01]` and \[source: escaped; added: 2026-01-01] verbatim. [source: owner; added: 2026-01-01]"#
  let bytes = Data(text.utf8)
  #expect(MemoryDocument.entries(in: bytes).first?.isMutable == true)
  #expect(
    MemoryDocument.reviewText(bytes)
      == #"Keep `[source: literal; added: 2026-01-01]` and \[source: escaped; added: 2026-01-01] verbatim."#
  )
  let fenced = Data("```text\n[source: code; added: 2026-01-01]\n```".utf8)
  #expect(MemoryDocument.reviewText(fenced) == String(decoding: fenced, as: UTF8.self))
  #expect(bytes == Data(text.utf8))
}

@Test @MainActor
func nativeSavedRecoveryRequiresConfirmationRefreshesReviewAndPreservesDraft() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (_, pending) = try savedRecoveryPendingAddition(fixture)
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url, autosaveDelay: .seconds(3600))
  await model.prepareSavedRecovery()
  #expect(model.savedRecovery == nil)
  await model.load()
  #expect(model.savedRecoveryRunID == pending.runID)
  await model.loadCandidates()
  await model.add()
  model.editorText = "Keep this unsaved draft. [source: fixture; added: 2026-10-17]"
  model.editorReason = "Retain local edit"
  model.editorChanged()
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  try await model.flushInputAndPersistence()
  let items = try encoder.encode(model.stagedItems)
  let before = try fixture.protectedState()
  var isPresentationBusy = false
  let observation = model.$savedRecovery.sink { presentation in
    if presentation != nil { isPresentationBusy = model.isBusy }
  }
  defer { observation.cancel() }
  await model.prepareSavedRecovery()
  #expect(!isPresentationBusy)
  #expect(model.savedRecovery?.actionableCount == 1)
  let suggestion = try #require(model.savedRecovery?.suggestions.first)
  #expect(!MemoryDocument.reviewText(suggestion.change.after).contains("[source:"))
  #expect(String(decoding: suggestion.change.after, as: UTF8.self).contains("[source:"))
  #expect(model.presentation == nil)
  #expect(try fixture.protectedState() == before)
  await model.refresh()
  #expect(model.savedRecovery == nil)
  await model.confirmSavedRecovery()
  #expect(model.candidates.isEmpty)
  await model.prepareSavedRecovery()
  model.configuration.settings.modelID = "changed selection"
  #expect(model.savedRecovery == nil)
  await model.confirmSavedRecovery()
  #expect(model.candidates.isEmpty)
  await model.refresh()
  await model.prepareSavedRecovery()
  #expect(model.savedRecovery != nil)
  model.isBusy = true
  await model.confirmSavedRecovery()
  #expect(model.savedRecovery != nil)
  model.isBusy = false
  await model.confirmSavedRecovery()
  #expect(model.failure == nil)
  #expect(model.savedRecovery == nil)
  #expect(model.section == "Memories")
  #expect(model.actionableCandidates.count == 1)
  #expect(model.presentation == nil)
  #expect(try encoder.encode(model.stagedItems) == items)
  let after = try fixture.protectedState()
  let changedPaths = after.filter { before[$0.key] != $0.value }.keys.sorted()
  #expect(changedPaths == [])
  await model.selectMemory(
    .candidate(try #require(model.actionableCandidates.first).change.id.rawValue))
  #expect(model.presentation != nil)
  #expect(try fixture.protectedState() == after)
  try await model.shutdown()
}
