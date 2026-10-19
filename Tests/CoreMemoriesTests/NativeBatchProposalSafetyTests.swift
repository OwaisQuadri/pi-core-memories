import Foundation
import Testing

@testable import CoreMemories

@Test func memoryBatchUndoPreservesIndependentlyPreparedScopeWithoutRestoringAuthority() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let path = "projects/\(String(repeating: "a", count: 64)).md"
  try fixture.write(
    "# Memory\n\n" + fact("Prepared project preference."),
    file: fixture.memory.appendingPathComponent(path))
  _ = try Git(repo: fixture.memory, environment: [:]).data(["add", "."])
  try fixture.advance()
  try fixture.populate()
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  try controller.confirmDetach(controller.checkoutPreview())
  let drafts = try MemoryDraftStore(
    repository: fixture.memory, journal: memoryBatchTestJournal(fixture.root))
  let session = try MemoryBatchSession(
    repository: fixture.memory, drafts: drafts, review: controller, allowedPaths: ["MEMORY.md"])
  let candidate = try #require(session.projection.candidates.first)
  let shown = try session.presentAcceptance(candidateID: candidate.change.id)
  try session.stage(shown)
  try session.preparePath(path)
  let prepared = session.projection
  #expect(prepared.entries.contains { $0.path == path })
  try session.stageManual(
    MemoryManagementRequest(
      operation: .add, base: prepared.draft.baseCommit, path: path,
      replacement: fact("Additional project intent."), reason: "Requested addition"))
  try session.undo()
  #expect(session.items.map(\.itemID) == [shown.itemID])
  #expect(session.projection.needsReview.isEmpty)
  try session.undo()
  let undone = session.projection
  #expect(undone.draft.batch?.items.isEmpty == true)
  #expect(undone.draft.batch?.binding.allowedPaths == prepared.draft.batch?.binding.allowedPaths)
  #expect(undone.draft.batch?.binding.preparedPaths == [path])
  #expect(undone.entries.map(\.expected) == prepared.entries.map(\.expected))
  #expect(undone.candidates.map(\.change.id) == prepared.candidates.map(\.change.id))
  #expect(throws: (any Error).self) { try session.stage(shown) }
  try session.stage(session.presentAcceptance(candidateID: candidate.change.id))
  #expect(session.projection.needsReview.isEmpty)
  #expect(session.projection.draft.batch?.binding.allowedPaths.contains(path) == true)
}

@Test(arguments: [1, 10_049])
func memoryBatchConstructorRejectsOutOfRangeOffsetsWithoutPhantomDrafts(contentCount: Int) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.write(
    "# Memory\n\n" + (0..<contentCount).map { fact("Entry \($0).") + "\n" }.joined(),
    file: fixture.memory.appendingPathComponent("MEMORY.md"))
  _ = try Git(repo: fixture.memory, environment: [:]).data(["add", "MEMORY.md"])
  try fixture.advance()
  let drafts = try MemoryDraftStore(
    repository: fixture.memory, journal: memoryBatchTestJournal(fixture.root))
  var validOffsetFailure: String?
  do {
    let session = try MemoryBatchSession(
      repository: fixture.memory, drafts: drafts, catalogOffset: contentCount - 1)
    #expect(session.projection.entryCount == contentCount)
    #expect(session.projection.entries.count == 1)
  } catch { validOffsetFailure = String(describing: error) }
  #expect(validOffsetFailure == nil, "R7 constructor must admit the actual final catalogue row")
  if contentCount == 1 {
    let sentinel = try MemoryBatchSession(
      repository: fixture.memory, drafts: drafts, catalogOffset: contentCount)
    #expect(sentinel.projection.entries.isEmpty)
  }
  for offset in [Int.min, -1, contentCount + 1, Int.max] {
    let before = try fixture.snapshot(drafts.journal)
    do {
      _ = try MemoryBatchSession(repository: fixture.memory, drafts: drafts, catalogOffset: offset)
      Issue.record("R7 constructor must reject offsets outside the actual catalogue")
    } catch {}
    #expect(
      try fixture.snapshot(drafts.journal) == before,
      "R7 invalid constructor input must not leave a newer phantom draft")
  }
}
