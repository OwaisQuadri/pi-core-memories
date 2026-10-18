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
  model.add()
  model.editorText = "Keep this unsaved draft. [source: fixture; added: 2026-10-17]"
  model.editorReason = "Retain local edit"
  model.editorChanged()
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let operations = try encoder.encode(model.operations)
  let before = try fixture.protectedState()
  await model.prepareSavedRecovery()
  #expect(model.savedRecovery?.actionableCount == 1)
  let suggestion = try #require(model.savedRecovery?.suggestions.first)
  #expect(!MemoryDocument.reviewText(suggestion.change.after).contains("[source:"))
  #expect(String(decoding: suggestion.change.after, as: UTF8.self).contains("[source:"))
  #expect(model.preview == nil)
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
  #expect(model.section == "Review")
  #expect(model.actionableCandidates.count == 1)
  #expect(model.preview == nil)
  #expect(try encoder.encode(model.operations) == operations)
  let after = try fixture.protectedState()
  let changedPaths = after.filter { before[$0.key] != $0.value }.keys.sorted()
  #expect(changedPaths == [])
  await model.showPreview(try #require(model.actionableCandidates.first))
  #expect(model.preview != nil)
  #expect(try fixture.protectedState() == after)
  try await model.shutdown()
}

@Test @MainActor
func nativeSaveFeedbackDoesNotExposeCommitIdentifiers() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try savedRecoveryPendingAddition(fixture)
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url, autosaveDelay: .seconds(3600))
  await model.load()
  await model.prepareSavedRecovery()
  await model.confirmSavedRecovery()
  await model.prepareCheckout()
  await model.detach()
  await model.showPreview(try #require(model.actionableCandidates.first))
  await model.approve()
  #expect(model.failure == nil)
  #expect(model.message == "Saved into memory")
  model.add()
  model.editorText = "Keep feedback clear. [source: fixture; added: 2026-10-18]"
  model.editorReason = "Keep this synthetic edit"
  model.editorChanged()
  await model.save()
  #expect(model.failure == nil)
  #expect(model.message == "Saved changes in one commit")
  try await model.shutdown()
}

@Test(arguments: [false, true], [false, true]) @MainActor
func nativeSavedReplyOffersRecoveryOnlyForChangedBaseSuggestions(
  isNotesOnly: Bool, isBaseChanged: Bool
) async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.persistenceFault = { event in
    if event == .beforeWrite("completion.json") { throw POSIXError(.EIO) }
  }
  store.beforePublication = { _ in throw POSIXError(.EIO) }
  #expect(throws: (any Error).self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try isNotesOnly ? transactionNotes($0) : transactionAdd($0) })
  }
  if isBaseChanged { try fixture.advance() }
  let configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let before = try fixture.snapshot(fixture.root)
  let model = AppModel(configURL: url)
  await model.load()
  let run = try #require(model.inspection?.runs.first)
  #expect(!run.isCompleted)
  #expect(run.attempts.last?.status == "Reply valid")
  #expect(run.approvedBase != nil)
  #expect(run.attempts.last?.suggestionCount == (isNotesOnly ? 0 : 1))
  #expect(model.resumableRun?.id == run.id)
  #expect(model.savedRecoveryRunID == (isBaseChanged && !isNotesOnly ? run.id : nil))
  #expect(model.savedRecovery == nil)
  #expect(try fixture.snapshot(fixture.root) == before)
  try await model.shutdown()
  if !isBaseChanged || isNotesOnly {
    _ = try transactionCompleted(
      fixture.store().run(
        selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled
      ))
  }
}

@Test @MainActor
func nativeSavedRecoveryRejectsAnUnloadedOrReplacedProfileWithoutPublishing() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  _ = try savedRecoveryPendingAddition(fixture)
  var configuration = queueConfiguration(fixture)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url)
  await model.prepareSavedRecovery()
  #expect(model.savedRecovery == nil)
  await model.load()
  await model.prepareSavedRecovery()
  #expect(model.savedRecovery != nil)
  configuration.settings.modelID = "replacement profile"
  try configuration.save(to: url)
  let before = try fixture.protectedState()
  await model.confirmSavedRecovery()
  #expect(model.failure != nil)
  #expect(model.candidates.isEmpty)
  #expect(try fixture.protectedState() == before)
  try await model.shutdown()
}
