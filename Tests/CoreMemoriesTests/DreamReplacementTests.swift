import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func dreamReplacementCannotCallForFreshInterruptedOrValidSavedReplies() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in throw CancellationError() }), reason: .cancelled)
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  let store = try fixture.store()
  store.persistenceFault = {
    if $0 == .afterDirectorySync("response.json") { throw POSIXError(.EIO) }
  }
  #expect(throws: DreamRunError.persistenceFailure) {
    try store.run(
      selection: fixture.selection, resume: .retryInterruptedCall,
      prepare: transactionUncalledPrepare, call: transactionNotes)
  }
  let saved = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.replacementUnavailable) {
    try fixture.store().run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == saved)
}
