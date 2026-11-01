import Darwin
import Foundation
import Testing

@testable import CoreMemories

func queueConfiguration(_ fixture: TransactionFixture) -> MemoryConfiguration {
  var configuration = MemoryConfiguration.defaults
  configuration.roots = DreamControlRoots(
    state: fixture.state.path, sessions: fixture.sessions.path, memory: fixture.memory.path,
    snippets: fixture.snippets.path, prompts: nil, globalAgents: nil)
  configuration.journal = fixture.root.appendingPathComponent("journal").path
  configuration.reviewState = fixture.root.appendingPathComponent("review").path
  configuration.diagnostics = fixture.root.appendingPathComponent("diagnostics").path
  return configuration
}

@Test func dreamQueueSnapshotReadsCommittedProgressWithoutChangingAnyFiles() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep A.", "Keep B."])
  let store = try fixture.store()
  _ = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0, records: 2) },
      call: { try transactionNotes($0) }))
  let before = try fixture.snapshot(fixture.root)
  let snapshot = DreamQueueSnapshot.read(configuration: queueConfiguration(fixture))
  let segments = try #require(snapshot.coverage?.segments)
  #expect(snapshot.unavailableReason == nil)
  #expect(segments.dreamt == 7)
  #expect(segments.undreamt == 7)
  #expect(segments.free == SessionReader.dreamBacklogBytes - 7)
  #expect(try fixture.snapshot(fixture.root) == before)
}
