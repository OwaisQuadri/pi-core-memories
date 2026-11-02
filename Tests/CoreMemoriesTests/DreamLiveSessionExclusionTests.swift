import Foundation
import Testing

@testable import CoreMemories

@Test func dreamLiveSessionExclusionSkipsBodyAndPreservesTrackedCursor() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let reader = try SessionReader(
    sessions: fixture.sessions, snippets: fixture.snippets, environment: [:])
  let first = try reader.prepare(progress: DreamProgress(), limits: DreamInputLimits())
  let progress = try DreamProgress(generation: 1, positions: first.positionsAfter)
  try fixture.append("malformed LIVE_SENTINEL body\n")
  var checked: [String] = []
  let batch = try reader.prepareProtected(
    progress: progress, limits: DreamInputLimits(), protect: { checked += $0 },
    admit: {
      checked += $0
      return $0
    }, excludedSessionIDs: ["one"])
  #expect(batch.positionsAfter == progress.positions)
  #expect(batch.exactSourceRecords.isEmpty)
  #expect(batch.admittedViews.isEmpty)
  #expect(!checked.contains { $0.contains("LIVE_SENTINEL") })
}

@Test func dreamWorkerLiveExclusionAdmitsHistoricalSessionOnly() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["LIVE_SENTINEL"])
  let other = fixture.sessions.appendingPathComponent("--fixture--/two.jsonl")
  try fixture.write(
    dreamHeader("two", cwd: fixture.root.path, name: nil) + "\n"
      + dreamUser("u", nil, dreamOld, "Historical green buttons.") + "\n", file: other)
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  var checked: [String] = []
  worker.protectionTransform = {
    checked += $0
    return $0
  }
  var start = workerStart(fixture)
  start["excludedSessionIDs"] = ["one"]
  try worker.send(start)
  let request = try worker.frame()
  #expect(request["type"] as? String == "modelRequest")
  #expect(!String(describing: request).contains("LIVE_SENTINEL"))
  #expect(!checked.contains { $0.contains("LIVE_SENTINEL") })
  try worker.send(workerReply(request, text: workerDecision(request)))
  #expect(try worker.frame()["status"] as? String == "completed")
  try worker.finish()
  let generation = fixture.state.appendingPathComponent("generations/1.json")
  #expect(!String(decoding: try Data(contentsOf: generation), as: UTF8.self).contains("one.jsonl"))
}

@Test func dreamWorkerSkipsInterruptedCallWhenItsSourceOpens() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  try first.send(workerStart(fixture))
  let request = try first.frame()
  let runID = try #require(request["runID"] as? String)
  try first.send(workerReply(request, category: "failed"))
  #expect(try first.frame()["status"] as? String == "pending")
  try first.finish()
  let retry = try DreamWorkerProcess()
  defer { retry.clean() }
  var start = workerStart(fixture, resume: "retryInterruptedCall")
  start["excludedSessionIDs"] = ["one"]
  try retry.send(start)
  #expect(try retry.frame()["status"] as? String == "noNewRecords")
  try retry.finish()
  #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("runs/\(runID)").path))
  #expect(FileManager.default.fileExists(atPath: fixture.source.path))
}

@Test func dreamWorkerSkipsSavedReplyAndDreamsNextClosedSession() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["LIVE_SENTINEL"])
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  try first.send(workerStart(fixture))
  let request = try first.frame()
  let runID = try #require(request["runID"] as? String)
  try first.send(workerReply(request, text: "Invalid semantic response"))
  #expect(try first.frame()["reason"] as? String == "invalidDecision")
  try first.finish()

  let other = fixture.sessions.appendingPathComponent("--fixture--/two.jsonl")
  try fixture.write(
    dreamHeader("two", cwd: fixture.root.path, name: nil) + "\n"
      + dreamUser("u", nil, dreamOld, "Historical green buttons.") + "\n", file: other)
  var start = workerStart(fixture)
  start["excludedSessionIDs"] = ["one"]
  let retry = try DreamWorkerProcess()
  defer { retry.clean() }
  try retry.send(start)
  let fresh = try retry.frame()
  #expect(fresh["type"] as? String == "modelRequest")
  #expect(!String(describing: fresh).contains("LIVE_SENTINEL"))
  try retry.send(workerReply(fresh, text: workerDecision(fresh)))
  #expect(try retry.frame()["status"] as? String == "completed")
  try retry.finish()
  #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("runs/\(runID)").path))
  #expect(FileManager.default.fileExists(atPath: fixture.source.path))

  let resumed = try DreamWorkerProcess()
  defer { resumed.clean() }
  try resumed.send(workerStart(fixture))
  let reopened = try resumed.frame()
  #expect(reopened["type"] as? String == "modelRequest")
  #expect(String(describing: reopened).contains("LIVE_SENTINEL"))
  try resumed.send(workerReply(reopened, text: workerDecision(reopened)))
  #expect(try resumed.frame()["status"] as? String == "completed")
  try resumed.finish()
}

@Test func dreamWorkerSkipsExactSavedRunOnlyWhileSourceIsLive() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["LIVE_SENTINEL"])
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  try first.send(workerStart(fixture))
  let request = try first.frame()
  try first.send(workerReply(request, text: "Invalid semantic response"))
  #expect(try first.frame()["reason"] as? String == "invalidDecision")
  try first.finish()

  let runID = try #require(request["runID"] as? String)
  let requestHash = try #require(request["requestHash"] as? String)
  let response = try Data(contentsOf: fixture.payload("response.json"))
  var start = workerStart(fixture, resume: "discardLiveSource")
  start["recoveryTarget"] = ["runID": runID, "requestHash": requestHash]
  let denied = try DreamWorkerProcess()
  defer { denied.clean() }
  try denied.send(start)
  #expect(try denied.frame()["status"] as? String == "blocked")
  try denied.finish()
  #expect(try Data(contentsOf: fixture.payload("response.json")) == response)

  let other = fixture.sessions.appendingPathComponent("--fixture--/two.jsonl")
  try fixture.write(
    dreamHeader("two", cwd: fixture.root.path, name: nil) + "\n"
      + dreamUser("u", nil, dreamOld, "Historical green buttons.") + "\n", file: other)
  start["excludedSessionIDs"] = ["one"]
  let skipped = try DreamWorkerProcess()
  defer { skipped.clean() }
  try skipped.send(start)
  let fresh = try skipped.frame()
  #expect(fresh["type"] as? String == "modelRequest")
  #expect(!String(describing: fresh).contains("LIVE_SENTINEL"))
  try skipped.send(workerReply(fresh, text: workerDecision(fresh)))
  #expect(try skipped.frame()["status"] as? String == "completed")
  try skipped.finish()
  let savedRun = fixture.state.appendingPathComponent("runs/\(runID)")
  #expect(!FileManager.default.fileExists(atPath: savedRun.path))
  #expect(FileManager.default.fileExists(atPath: fixture.source.path))
}
