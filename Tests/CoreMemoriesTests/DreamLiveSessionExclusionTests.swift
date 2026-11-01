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

@Test func dreamWorkerLiveExclusionRefusesExactPendingWithoutResealing() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  try first.send(workerStart(fixture))
  let request = try first.frame()
  try first.send(workerReply(request, category: "failed"))
  #expect(try first.frame()["status"] as? String == "pending")
  try first.finish()
  let names = ["input.json", "context.json", "request.json"]
  let before = try names.map { try Data(contentsOf: fixture.payload($0)) }
  let retry = try DreamWorkerProcess()
  defer { retry.clean() }
  var start = workerStart(fixture, resume: "retryInterruptedCall")
  start["excludedSessionIDs"] = ["one"]
  try retry.send(start)
  #expect(try retry.frame()["status"] as? String == "blocked")
  try retry.finish()
  #expect(try names.map { try Data(contentsOf: fixture.payload($0)) } == before)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("generations/1.json").path))
}
