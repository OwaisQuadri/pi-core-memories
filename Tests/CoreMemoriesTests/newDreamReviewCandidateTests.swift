import Foundation
import Testing

@testable import CoreMemories

@Test func completedReviewReadDoesNotReadSourcesCallCallbacksOrChangeFiles() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  _ = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  try FileManager.default.removeItem(at: fixture.sessions)
  try FileManager.default.removeItem(at: fixture.snippets)
  let reopened = try fixture.store()
  reopened.clock = {
    Issue.record("read must not call clock")
    return Date()
  }
  reopened.isCancelled = {
    Issue.record("read must not call cancellation")
    return false
  }
  reopened.persistenceFault = { _ in Issue.record("read must not persist") }
  reopened.beforePublication = { _ in Issue.record("read must not publish") }
  let before = try fixture.snapshot(fixture.root)
  let bundles = try reopened.verifiedCompletedReviewCandidates()
  #expect(bundles.count == 1)
  #expect(bundles[0].changes.count == 1)
  #expect(try fixture.snapshot(fixture.root) == before)
}
