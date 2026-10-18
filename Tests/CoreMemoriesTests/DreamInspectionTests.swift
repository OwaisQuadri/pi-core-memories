import Foundation
import Testing

@testable import CoreMemories

@Test func dreamInspectionShowsRejectedFieldsAndReplacementSelectionWithoutMutation() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  _ = try store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: {
      let valid = try transactionAdd($0)
      return try DreamCompletedResponse(
        text: valid.text.replacingOccurrences(of: "\"text\":", with: "\"memory\":"))
    })
  let replacement = try DreamSelectedCall(
    provider: "fixture", modelID: "replacement", thinkingLevel: "high")
  _ = try store.run(
    selection: replacement, resume: .replaceInvalidResponse,
    prepare: transactionUncalledPrepare, call: { try transactionAdd($0) })
  let before = try fixture.snapshot(fixture.state)
  let inspection = try DreamInspection.read(stateRoot: fixture.state)
  let run = try #require(inspection.runs.first)
  #expect(run.diagnostic == nil)
  #expect(run.attempts.count == 2)
  #expect(run.attempts[0].status == "Rejected reply")
  #expect(run.attempts[0].diagnostic?.contains("missing [text]") == true)
  #expect(run.attempts[0].diagnostic?.contains("unexpected [memory]") == true)
  #expect(run.attempts[1].status == "Reply valid")
  #expect(run.attempts[1].provider == replacement.provider)
  #expect(run.attempts[1].modelID == replacement.modelID)
  #expect(run.attempts[1].thinkingLevel == replacement.thinkingLevel)
  #expect(try fixture.snapshot(fixture.state) == before)
}

@Test(arguments: ["project", "outsideGit", "unresolved"])
func dreamInspectionNamesConflictingScopeReasonWithoutMutation(resolution: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let isUnresolved = resolution == "unresolved"
  let cwd =
    resolution == "project"
    ? fixture.memory.path
    : isUnresolved ? fixture.root.appendingPathComponent("gone").path : fixture.root.path
  try fixture.populate(cwd: cwd)
  let store = try fixture.store()
  _ = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: {
        let valid = try transactionNotes($0)
        return try DreamCompletedResponse(
          text: valid.text.replacingOccurrences(
            of: isUnresolved ? "unresolvedScope" : "notDurable",
            with: isUnresolved ? "notDurable" : "unresolvedScope"))
      }), reason: .invalidDecision)
  let before = try fixture.snapshot(fixture.state)
  let inspection = try DreamInspection.read(stateRoot: fixture.state)
  let attempt = try #require(inspection.runs.first?.attempts.first)
  #expect(attempt.status == "Rejected reply")
  #expect(
    attempt.diagnostic?.contains(
      isUnresolved
        ? "unresolved evidence requires an unresolvedScope note"
        : "unresolvedScope cannot be used for resolved evidence") == true)
  #expect(try fixture.snapshot(fixture.state) == before)
}
