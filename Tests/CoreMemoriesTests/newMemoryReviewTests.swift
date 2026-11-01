import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func reviewPreviewDoesNotApproveAndRejectDeferSurviveRestart() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep A.", "Keep B.", "Keep C."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let rows = try controller!.list()
  #expect(rows.count == 3)
  let original = try fixture.snapshot(fixture.memory)
  let date = Date(timeIntervalSince1970: 1_783_036_799)
  let preview = try controller!.preview(candidateID: rows[0].change.id, clockDate: date)
  #expect(preview.after != rows[0].change.after)
  #expect(preview.change.sources[0].exactText == rows[0].change.sources[0].exactText)
  #expect(MemoryDocument.entries(in: preview.replacement).filter { $0.identity != nil }.count == 1)
  #expect(try fixture.snapshot(fixture.memory) == original)
  try controller!.reject(candidateID: rows[1].change.id)
  try controller!.deferCandidate(candidateID: rows[2].change.id)
  controller = nil
  let reopened = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let dispositions = try reopened.list().map(\.disposition)
  #expect(dispositions == [.pending, .rejected, .deferred])
  #expect(try fixture.snapshot(fixture.memory) == original)
  let deferredPreview = try reopened.preview(candidateID: rows[2].change.id, clockDate: date)
  #expect(deferredPreview.change.id == rows[2].change.id)
  #expect(throws: (any Error).self) {
    try reopened.preview(candidateID: rows[1].change.id, clockDate: date)
  }
}

@Test func reviewAbsentProjectAddsOnlyShownNativeEntryAndLeavesGlobalPending() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  try fixture.populate(cwd: project.path)
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) }))
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: sources, environment: [:])
  let rows = try controller.list()
  let row = rows.first { $0.change.path.hasPrefix("projects/") }!
  try controller.confirmDetach(controller.checkoutPreview())
  let preview = try controller.preview(
    candidateID: row.change.id, clockDate: Date(timeIntervalSince1970: 1_783_036_799))
  #expect(preview.replacement.starts(with: Data("# Memory\n\n".utf8)))
  _ = try controller.apply(preview)
  #expect(try controller.list().first { $0.change.path == "MEMORY.md" }?.disposition == .pending)
  #expect(MemoryDocument.entries(in: preview.replacement).filter(\.isMutable).count == 1)
}
