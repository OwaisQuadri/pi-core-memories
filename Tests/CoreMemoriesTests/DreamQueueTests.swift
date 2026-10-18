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

private func queueJSON() -> [String: Any] {
  [
    "backlogBytes": 100, "backlogLimitBytes": 80, "undreamtBytes": 60, "nextBytes": 20,
    "plannedBytes": 30, "completedBytes": 10, "repeatedRecords": 0,
    "estimateSeconds": NSNull(),
  ]
}

@Test func dreamQueueCoverageUsesCommittedBytesAndNeverNegativeCapacity() throws {
  let coverage = try DreamQueueCoverage(json: queueJSON())
  let segments = try #require(coverage.segments)
  #expect(segments.dreamt == 50)
  #expect(segments.undreamt == 50)
  #expect(segments.free == 30)
  #expect(segments.total == 130)
  var overrun = queueJSON()
  overrun["backlogLimitBytes"] = 10
  let full = try #require(DreamQueueCoverage(json: overrun).segments)
  #expect(full.free == 0)
  #expect(full.total == 100)
  let maximum: UInt64 = 9_007_199_254_740_991
  let bounded = try DreamQueueCoverage(
    backlogBytes: maximum, backlogLimitBytes: maximum, undreamtBytes: maximum,
    nextBytes: 0, plannedBytes: maximum, completedBytes: maximum)
  #expect(bounded.segments?.total == maximum * 2)
}

@Test func dreamQueueUnknownSavedReplayDoesNotInventZeroBacklog() throws {
  var json = queueJSON()
  for key in ["backlogBytes", "backlogLimitBytes", "undreamtBytes", "nextBytes"] {
    json[key] = NSNull()
  }
  let coverage = try DreamQueueCoverage(json: json)
  #expect(coverage.segments == nil)
  #expect(coverage.plannedBytes == 30)
}

@Test(arguments: [
  "negative", "fraction", "boolean", "overflow", "inconsistent", "missing", "completed", "next",
])
func dreamQueueMalformedCoverageIsRejectedWithoutArithmeticTraps(_ variant: String) {
  var json = queueJSON()
  switch variant {
  case "negative": json["backlogBytes"] = -1
  case "fraction": json["plannedBytes"] = 0.5
  case "boolean": json["completedBytes"] = true
  case "overflow": json["backlogBytes"] = UInt64.max
  case "inconsistent": json["undreamtBytes"] = NSNull()
  case "missing": json.removeValue(forKey: "plannedBytes")
  case "completed": json["completedBytes"] = 31
  default: json["nextBytes"] = 31
  }
  #expect(throws: (any Error).self) { try DreamQueueCoverage(json: json) }
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

@Test(arguments: ["missing", "empty", "busy", "invalid", "wrongSessions", "wrongRepository"])
func dreamQueueSnapshotFailsClosedWithoutInitializingOrRepairingState(_ variant: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  var configuration = queueConfiguration(fixture)
  var lock: Int32?
  defer {
    if let lock {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
  }
  if variant == "empty" {
    try FileManager.default.createDirectory(
      at: fixture.state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  } else if variant != "missing" {
    _ = try fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { _ in throw CancellationError() })
  }
  if variant == "busy" {
    let file = open(fixture.state.appendingPathComponent("writer.lock").path, O_RDONLY)
    #expect(file >= 0)
    #expect(flock(file, LOCK_EX | LOCK_NB) == 0)
    lock = file
  } else if variant == "invalid" {
    try Data("{}".utf8).write(to: fixture.state.appendingPathComponent("generations/0.json"))
  } else if variant == "wrongSessions" {
    configuration.roots?.sessions = fixture.root.appendingPathComponent("other-sessions").path
  } else if variant == "wrongRepository" {
    let other = fixture.root.appendingPathComponent("other-memory")
    try MemoryStore.initialize(repo: other, environment: [:])
    configuration.roots?.memory = other.path
  }
  let before = try fixture.snapshot(fixture.root)
  let snapshot = DreamQueueSnapshot.read(configuration: configuration)
  #expect(snapshot.coverage == nil)
  #expect(snapshot.unavailableReason != nil)
  if variant == "busy" { #expect(snapshot.unavailableReason?.contains("busy") == true) }
  if variant == "missing" { #expect(!FileManager.default.fileExists(atPath: fixture.state.path)) }
  #expect(try fixture.snapshot(fixture.root) == before)
}

@Test func staleSavedInferenceDoesNotAdvanceQueueOrAdmitReviewCandidates() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  store.beforePublication = { _ in throw CancellationError() }
  #expect(throws: CancellationError.self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) })
  }
  try fixture.advance()
  let before = DreamQueueSnapshot.read(configuration: queueConfiguration(fixture))
  _ = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .staleUnpublishedPlans)
  let files = try fixture.snapshot(fixture.root)
  let after = DreamQueueSnapshot.read(configuration: queueConfiguration(fixture))
  #expect(before.coverage?.segments?.undreamt == after.coverage?.segments?.undreamt)
  #expect(after.coverage?.segments?.dreamt == 0)
  #expect(after.coverage?.segments?.undreamt == 28)
  #expect(try fixture.store().verifiedCompletedReviewCandidates().isEmpty)
  #expect(try fixture.snapshot(fixture.root) == files)
}

@Test func dreamQueueDefaultProfileRejectsUnmappedAgentAndStrippingSources() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  var configuration = MemoryConfiguration.defaults
  configuration.settings.agentDirectory = fixture.root.path
  let snippets = fixture.root.appendingPathComponent("extensions/prompt-snippets/snippets")
  let prompts = fixture.root.appendingPathComponent("prompts")
  let roles = try configuration.queueSourceRoles(
    sessions: fixture.sessions, stripping: [snippets, prompts])
  #expect(roles.isSnippetsPresent)
  #expect(roles.isPromptsPresent)
  #expect(throws: (any Error).self) {
    try configuration.queueSourceRoles(
      sessions: fixture.root.appendingPathComponent("other-sessions"), stripping: [snippets])
  }
  #expect(throws: (any Error).self) {
    try configuration.queueSourceRoles(sessions: fixture.sessions, stripping: [fixture.snippets])
  }
  #expect(throws: (any Error).self) {
    try configuration.queueSourceRoles(sessions: fixture.sessions, stripping: [prompts, snippets])
  }
}
