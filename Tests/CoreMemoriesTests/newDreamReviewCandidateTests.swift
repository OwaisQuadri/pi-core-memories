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

@Test(arguments: [
  "input.json", "context.json", "response.json", "decisions.json", "completion.json",
])
func completedReviewRefusesChangedAuthorityWithoutWriting(payload: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  _ = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let file = try fixture.payload(payload)
  var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
  object["unboundField"] = "tampered"
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
  let before = try fixture.snapshot(fixture.root)
  #expect(throws: (any Error).self) { try store.verifiedCompletedReviewCandidates() }
  #expect(try fixture.snapshot(fixture.root) == before)
}

@Test func completedReviewRefusesMissingProposalRefAndChangedReceipt() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  let report = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let receiptDirectory = try fixture.payload("receipts")
  let receiptFile = receiptDirectory.appendingPathComponent(
    report.proposals[0].planHash.rawValue + ".json")
  let original = try Data(contentsOf: receiptFile)
  var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
  object["planHash"] = String(repeating: "0", count: 64)
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: receiptFile)
  #expect(throws: (any Error).self) { try store.verifiedCompletedReviewCandidates() }
  try original.write(to: receiptFile)
  _ = try Git(repo: fixture.memory, environment: [:]).data([
    "update-ref", "-d", report.proposals[0].ref,
  ])
  let before = try fixture.snapshot(fixture.root)
  #expect(throws: (any Error).self) { try store.verifiedCompletedReviewCandidates() }
  #expect(try fixture.snapshot(fixture.root) == before)
}
