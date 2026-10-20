import Darwin
import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

private func nativeReportEvent(_ report: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: ["event": "report", "report": report])
}

@Test(arguments: ["callbackFailure", "workerFailure", "protocolFailure", "invalidDecision"])
@MainActor
func nativeStatusKeepsTechnicalDetailsOutOfThePrimaryExplanation(_ reason: String) throws {
  let model = AppModel(configURL: URL(fileURLWithPath: "/unused-synthetic-profile"))
  let detail = "Synthetic provider error: quota exceeded"
  try model.receive(
    nativeReportEvent([
      "status": "pending", "reason": reason, "detail": detail,
    ]))
  #expect(!model.dreamDetail.isEmpty)
  #expect(!model.dreamDetail.contains(detail))
  #expect(model.invocationStatus?.detail == detail)
}

private func savedNativeReport(
  configuration: MemoryConfiguration, runID: String
) throws -> URL {
  let root = try DreamStateDirectory.openRoot(URL(fileURLWithPath: configuration.diagnostics))
  let name = UUID().uuidString
  let invocation = try root.child(name, isCreating: true)
  try invocation.installReviewFile(
    JSONSerialization.data(withJSONObject: [
      "requestedSettings": try JSONSerialization.jsonObject(
        with: DreamRunEncoding.encode(configuration.settings)),
      "request": [
        "roots": try JSONSerialization.jsonObject(
          with: DreamRunEncoding.encode(configuration.roots!)),
        "projectBindings": configuration.projectBindings,
      ],
    ]), name: "request.json")
  try invocation.installReviewFile(
    nativeReportEvent([
      "status": "pending", "reason": "staleUnpublishedPlans", "runID": runID,
    ]), name: "event-1.json")
  return URL(fileURLWithPath: configuration.diagnostics).appendingPathComponent(name)
}

@Test @MainActor func nativeStaleReportSurvivesReloadWithoutClaimingCompletedProgress() async throws
{
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
  let pending = try transactionPending(
    fixture.store().run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled),
    reason: .staleUnpublishedPlans)
  let configuration = queueConfiguration(fixture)
  _ = try savedNativeReport(configuration: configuration, runID: pending.runID)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let before = try fixture.snapshot(fixture.root)
  let model = AppModel(configURL: url)
  await model.load()
  #expect(!model.isBusy)
  #expect(model.invocationStatus?.isPublicationBlocked == true)
  #expect(model.dreamPhase == "Publication blocked")
  #expect(model.dreamDetail.contains("No queue progress advanced"))
  #expect(model.dreamDetail.contains("no new review candidates were admitted"))
  #expect(model.dreamDetail.contains("Retry and Replace do not repair"))
  let deadline = ContinuousClock.now + .seconds(5)
  while model.isQueueLoading && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(model.queueCoverage?.segments?.undreamt == 28)
  let event = try JSONSerialization.data(withJSONObject: [
    "event": "progress",
    "coverage": [
      "backlogBytes": NSNull(), "backlogLimitBytes": NSNull(), "undreamtBytes": NSNull(),
      "nextBytes": NSNull(), "plannedBytes": 28, "completedBytes": 0,
      "repeatedRecords": 0, "estimateSeconds": NSNull(),
    ],
  ])
  model.receive(event)
  model.receive(
    try nativeReportEvent([
      "status": "pending", "reason": "staleUnpublishedPlans", "runID": pending.runID,
    ]))
  #expect(model.eventCoverage?.completedBytes == 0)
  #expect(model.queueCoverage?.segments?.undreamt == 28)
  #expect(try fixture.snapshot(fixture.root) == before)
  var otherProfile = configuration
  otherProfile.settings.agentDirectory = fixture.root.appendingPathComponent("another-agent").path
  #expect(
    try DreamInvocationStatus.read(
      configuration: otherProfile, inspection: DreamInspection.read(stateRoot: fixture.state))
      == nil)
  let recoveryStore = try fixture.store()
  _ = try transactionCompleted(
    recoveryStore.confirmSavedRecovery(recoveryStore.previewSavedRecovery(runID: pending.runID)))
  model.isDreamRunning = true
  model.receive(try JSONSerialization.data(withJSONObject: ["phase": "modelCall"]))
  await model.refresh()
  #expect(model.dreamPhase == "Model working")
  #expect(model.invocationStatus?.isPublicationBlocked == true)
  model.isDreamRunning = false
  await model.refresh()
  #expect(model.inspection?.runs.first?.isCompleted == true)
  #expect(model.invocationStatus == nil)
  #expect(model.dreamPhase == "Idle")
  #expect(model.dreamDetail.isEmpty)
  try await model.shutdown()
}

@Test @MainActor
func nativeLatestStatusSurvivesMoreThan256RetainedInvocationsWithoutReadingObsoletePayloads()
  async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (_, pending) = try savedRecoveryPendingAddition(fixture)
  let configuration = queueConfiguration(fixture)
  let diagnostics = URL(fileURLWithPath: configuration.diagnostics)
  let root = try DreamStateDirectory.openRoot(diagnostics)
  for _ in 0..<257 {
    let name = UUID().uuidString
    let old = try root.child(name, isCreating: true)
    try old.installReviewFile(Data("obsolete invalid JSON".utf8), name: "request.json")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)],
      ofItemAtPath: diagnostics.appendingPathComponent(name).path)
  }
  _ = try savedNativeReport(configuration: configuration, runID: pending.runID)
  var otherProfile = configuration
  otherProfile.settings.modelID = "another profile"
  let newer = try savedNativeReport(configuration: otherProfile, runID: pending.runID)
  try FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: newer.path)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  #expect(throws: DreamRunError.limitExceeded) { try root.names(maximum: 256) }
  #expect(try root.names(maximum: Int.max).count == 259)
  let before = try fixture.snapshot(fixture.root)
  let model = AppModel(configURL: url)
  await model.load()
  #expect(model.failure == nil)
  #expect(model.invocationStatus?.runID == pending.runID)
  #expect(model.invocationStatus?.isPublicationBlocked == true)
  #expect(try fixture.snapshot(fixture.root) == before)
  try await model.shutdown()
}

@Test func nativeStatusLookupDoesNotReadRequestsOutsideTheRecent256Invocations() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let configuration = queueConfiguration(fixture)
  let diagnostics = URL(fileURLWithPath: configuration.diagnostics)
  let root = try DreamStateDirectory.openRoot(diagnostics)
  let name = UUID().uuidString
  try root.child(name, isCreating: true).installReviewFile(
    Data("obsolete invalid JSON".utf8), name: "request.json")
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 1)],
    ofItemAtPath: diagnostics.appendingPathComponent(name).path)
  var otherProfile = configuration
  otherProfile.settings.modelID = "another profile"
  for _ in 0..<256 {
    _ = try savedNativeReport(configuration: otherProfile, runID: UUID().uuidString)
  }
  let before = try fixture.snapshot(diagnostics)
  #expect(try DreamInvocationStatus.read(configuration: configuration, inspection: nil) == nil)
  #expect(try fixture.snapshot(diagnostics) == before)
}

@Test @MainActor
func nativeStatusReadFailureIsUnavailableRatherThanRetainingTheOldReport() async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (_, pending) = try savedRecoveryPendingAddition(fixture)
  let configuration = queueConfiguration(fixture)
  let invocation = try savedNativeReport(configuration: configuration, runID: pending.runID)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url)
  await model.load()
  #expect(model.invocationStatus?.isPublicationBlocked == true)
  #expect(chmod(invocation.appendingPathComponent("request.json").path, 0o644) == 0)
  await model.refresh()
  #expect(model.invocationStatus == nil)
  #expect(model.dreamPhase == "Status unavailable")
  #expect(model.dreamDetail.contains("status unavailable"))
  #expect(chmod(invocation.appendingPathComponent("request.json").path, 0o600) == 0)
  await model.refresh()
  #expect(model.invocationStatus?.isPublicationBlocked == true)
  #expect(model.dreamPhase == "Publication blocked")
  #expect(!model.dreamDetail.contains("status unavailable"))
  try await model.shutdown()
}

@Test @MainActor
func nativeRefreshAndTerminalInvocationReloadAuthoritativeSuggestionsAndClearPreview() async throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  var configuration = queueConfiguration(fixture)
  let control = fixture.root.appendingPathComponent("control.ts")
  try fixture.write("export {}", file: control)
  let pi = fixture.root.appendingPathComponent("fake-pi")
  try fixture.write(
    """
    #!/bin/zsh
    IFS= read -r line
    printf '%s\\n' '{"type":"response","id":"commands","success":true,"data":{"commands":[{"name":"memory-dream-control"},{"name":"memory-dream-cancel"}]}}'
    IFS= read -r line
    printf '%s\\n' '{"type":"response","id":"state","success":true,"data":{"model":{"provider":"fixture","id":"selected"},"thinkingLevel":"off"}}'
    IFS= read -r line
    printf '%s\\n' '{"type":"extension_ui_request","method":"notify","message":"{\\"version\\":1,\\"type\\":\\"core-memory-control\\",\\"event\\":\\"report\\",\\"report\\":{\\"status\\":\\"completed\\"}}"}'
    printf '%s\\n' '{"type":"response","id":"dream","success":true}'
    while IFS= read -r line; do :; done
    """, file: pi)
  #expect(chmod(pi.path, 0o700) == 0)
  configuration.settings = MemoryAppSettings(
    piExecutable: pi.path, agentDirectory: fixture.root.path, controlExtension: control.path)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let model = AppModel(configURL: url)
  model.section = "Memories"
  await model.load()
  #expect(model.actionableCandidates.count == 1)
  await model.loadCandidates()
  await model.selectMemory(.candidate(try #require(model.candidates.first).change.id.rawValue))
  #expect(model.presentation != nil)
  try fixture.append(dreamUser("u1", nil, dreamOld, "Keep B.") + "\n")
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  model.run(.start)
  let deadline = ContinuousClock.now + .seconds(10)
  while (model.isDreamRunning || model.isBusy || model.actionableCandidates.count != 2)
    && ContinuousClock.now < deadline
  {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(!model.isDreamRunning)
  try #require(!model.isBusy)
  #expect(model.failure == nil)
  #expect(model.actionableCandidates.count == 2)
  #expect(model.presentation == nil)
  model.section = "Dreams"
  await model.selectMemory(nil)
  await model.loadCandidates()
  await model.selectMemory(.candidate(try #require(model.candidates.first).change.id.rawValue))
  #expect(model.presentation != nil)
  try fixture.append(dreamUser("u2", nil, dreamOld, "Keep C.") + "\n")
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  await model.refresh()
  #expect(model.actionableCandidates.count == 3)
  #expect(model.presentation == nil)
  let first = model.actionableCandidates[0]
  let second = model.actionableCandidates[1]
  await model.disposition(first, isRejected: true)
  await model.disposition(second, isRejected: false)
  #expect(model.actionableCandidates.count == 1)
  #expect(model.reviewedCandidates.isEmpty)
  #expect(model.stagedItems.count == 2)
  await model.save()
  #expect(model.message == "Decisions saved")
  #expect(model.actionableCandidates.count == 2)
  #expect(model.actionableCandidates.contains { $0.disposition == .deferred })
  #expect(model.reviewedCandidates.count == 1)
  #expect(model.reviewedCandidates.first?.disposition == .rejected)
  try await model.shutdown()
}
