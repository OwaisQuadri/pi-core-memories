import Foundation
import Testing

@testable import CoreMemories

private struct ReviewFlowBatchTiming: Encodable {
  let repetition: Int
  let isWarmup: Bool
  var fixtureMilliseconds = 0.0
  var preparationMilliseconds = 0.0
  var firstDisplayMilliseconds = 0.0
  var previewMilliseconds = 0.0
  var stagingMilliseconds = 0.0
  var durabilityMilliseconds = 0.0
  var publicationMilliseconds = 0.0
  var reconciliationMilliseconds = 0.0
  var workflowMilliseconds = 0.0
  var recoveryMilliseconds = 0.0
  var initialApprovedBytes = 0
  var approvedBytes = 0
  var completedApprovals = 0
  var publicationCount = 0
}

private func reviewBatchTimed<Value>(_ action: () throws -> Value) rethrows -> (Value, Double) {
  let start = DispatchTime.now().uptimeNanoseconds
  let value = try action()
  return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CORE_MEMORY_REVIEW_BATCH"] == "1"))
func reviewFlowBatchPreservesApprovedSiblingsSourcesAndCheckout() throws {
  let repetitions: [Int]
  if let raw = ProcessInfo.processInfo.environment["CORE_MEMORY_REVIEW_REPETITION"] {
    guard let repetition = Int(raw), (0...5).contains(repetition) else {
      throw MemoryError("expected a review-flow repetition from zero through five")
    }
    repetitions = [repetition]
  } else {
    repetitions = Array(0...5)
  }
  for repetition in repetitions {
    let (fixture, fixtureTime) = try reviewBatchTimed { try ReviewFlowFixture() }
    defer { fixture.transaction.clean() }
    let preserved = try fixture.preservedFiles()
    let git = Git(repo: fixture.transaction.memory, environment: [:])
    let base = try fixture.transaction.main()
    let original = try git.data(["show", "refs/heads/main:MEMORY.md"])
    var expectedDocument = original
    var expectedEntries = fixture.retainedEntries
    var timing = ReviewFlowBatchTiming(repetition: repetition, isWarmup: repetition == 0)
    timing.fixtureMilliseconds = fixtureTime
    timing.initialApprovedBytes = original.count
    print("REVIEW_BATCH_BEGIN \(repetition)")
    let workflowStart = DispatchTime.now().uptimeNanoseconds
    let ((controller, drafts, session), preparation) = try reviewBatchTimed {
      let controller = try fixture.controller()
      let drafts = try MemoryDraftStore(
        repository: fixture.transaction.memory,
        journal: memoryBatchTestJournal(fixture.transaction.root))
      let session = try MemoryBatchSession(
        repository: fixture.transaction.memory, drafts: drafts, review: controller,
        date: ReviewFlowFixture.reviewDate)
      return (controller, drafts, session)
    }
    timing.preparationMilliseconds = preparation
    let rows = session.projection.candidates
    try #require(
      rows.filter { $0.disposition == .approved }.count == ReviewFlowFixture.retainedCount)
    let pending = rows.filter { $0.disposition == .pending }.sorted {
      $0.change.sources[0].witness.byteRange.lowerBound
        < $1.change.sources[0].witness.byteRange.lowerBound
    }
    try #require(pending.count == ReviewFlowFixture.pendingCount)
    for (index, row) in pending.enumerated() {
      let (presentation, preview) = try reviewBatchTimed {
        try session.presentAcceptance(candidateID: row.change.id)
      }
      timing.previewMilliseconds += preview
      if index == 0 { timing.firstDisplayMilliseconds = preview }
      let (_, staging) = try reviewBatchTimed {
        session.select(presentation.itemID)
        try session.stage(presentation)
      }
      timing.stagingMilliseconds += staging
      try #require(
        MemoryDocument.sourceAnnotations(in: presentation.after)
          == MemoryDocument.sourceAnnotations(in: row.change.after))
      let entry = try #require(MemoryDocument.entries(in: presentation.after).first)
      expectedEntries[try #require(entry.identity)] = presentation.after
      expectedDocument.append(Data("\n".utf8) + presentation.after)
    }
    let (_, durability) = try reviewBatchTimed {
      try session.acknowledgePersistence(drafts.persistBatch(session.persistenceRequest))
    }
    timing.durabilityMilliseconds = durability
    try #require(try fixture.transaction.main() == base)
    let (result, publication) = try reviewBatchTimed { try session.save() }
    timing.publicationMilliseconds = publication
    guard case .saved(let receipt) = result, let commit = receipt.commit else {
      throw MemoryError("synthetic review batch did not publish")
    }
    timing.completedApprovals = session.projection.draft.batch?.items.count ?? 0
    let (reconciled, reconciliation) = try reviewBatchTimed { try controller.list() }
    timing.reconciliationMilliseconds = reconciliation
    timing.workflowMilliseconds =
      Double(DispatchTime.now().uptimeNanoseconds - workflowStart) / 1_000_000
    try #require(reconciled.allSatisfy { $0.disposition == .approved })
    let approved = try git.data(["show", "refs/heads/main:MEMORY.md"])
    timing.approvedBytes = approved.count
    timing.publicationCount = try Int(git.text(["rev-list", "--count", base + ".." + commit])) ?? 0
    try #require(timing.publicationCount == 1)
    try #require(timing.completedApprovals == ReviewFlowFixture.pendingCount)
    try #require(approved == expectedDocument)
    let entries = MemoryDocument.entries(in: approved).filter(\.isMutable)
    try #require(entries.count == ReviewFlowFixture.pendingCount + ReviewFlowFixture.retainedCount)
    try #require(Set(entries.compactMap(\.identity)).count == entries.count)
    for entry in entries {
      let identity = try #require(entry.identity)
      try #require(entry.bytes == expectedEntries[identity])
    }
    try #require(MemoryDocument.failures(in: approved).isEmpty)
    try #require(
      MemoryDocument.sourceAnnotations(in: approved).sorted()
        == fixture.candidates.flatMap { MemoryDocument.sourceAnnotations(in: $0.change.after) }
        .sorted())
    try #require(try fixture.preservedFiles() == preserved)
    let (recovered, recovery) = try reviewBatchTimed {
      try drafts.recoverBatch(
        draftID: receipt.draftID, revision: receipt.revision, review: controller)
    }
    timing.recoveryMilliseconds = recovery
    guard case .saved(let recoveredReceipt) = recovered else {
      throw MemoryError("synthetic review batch did not recover its receipt")
    }
    try #require(try memoryBatchDigest(recoveredReceipt) == memoryBatchDigest(receipt))
    try #require(try fixture.transaction.main() == commit)
    try #require(try fixture.preservedFiles() == preserved)
    let reopened = try controller.list()
    try #require(reopened.map(\.change.id) == fixture.candidates.map(\.change.id))
    for (original, recovered) in zip(fixture.candidates, reopened) {
      try #require(original.change.after == recovered.change.after)
      try #require(original.change.sources.map(\.id) == recovered.change.sources.map(\.id))
      try #require(
        original.change.sources.map(\.exactText) == recovered.change.sources.map(\.exactText))
      try #require(
        original.change.sources.map(\.witness) == recovered.change.sources.map(\.witness))
    }
    print(
      "REVIEW_BATCH_RESULT " + String(decoding: try JSONEncoder().encode(timing), as: UTF8.self))
  }
}
