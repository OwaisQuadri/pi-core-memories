import Darwin
import Foundation
import Testing

@testable import CoreMemories
@testable import CoreMemoriesApp

private func nativeReportEvent(_ report: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: ["event": "report", "report": report])
}

private func savedNativeReport(
  configuration: MemoryConfiguration, runID: String
) throws {
  let root = try DreamStateDirectory.openRoot(URL(fileURLWithPath: configuration.diagnostics))
  let invocation = try root.child(UUID().uuidString, isCreating: true)
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
  try savedNativeReport(configuration: configuration, runID: pending.runID)
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
  try await model.shutdown()
  #expect(model.eventCoverage?.completedBytes == 0)
  #expect(model.queueCoverage?.segments?.undreamt == 28)
  #expect(try fixture.snapshot(fixture.root) == before)
  var otherProfile = configuration
  otherProfile.settings.agentDirectory = fixture.root.appendingPathComponent("another-agent").path
  #expect(
    try DreamInvocationStatus.read(
      configuration: otherProfile, inspection: DreamInspection.read(stateRoot: fixture.state))
      == nil)
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
  model.section = "Review"
  await model.load()
  #expect(model.actionableCandidates.count == 1)
  #expect(!model.isShowingReviewedCandidates)
  await model.loadCandidates()
  await model.showPreview(try #require(model.candidates.first))
  #expect(model.preview != nil)
  try fixture.append(dreamUser("u1", nil, dreamOld, "Keep B.") + "\n")
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  model.run(.start)
  let deadline = ContinuousClock.now + .seconds(10)
  while (model.isDreamRunning || model.actionableCandidates.count != 2)
    && ContinuousClock.now < deadline
  {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(!model.isDreamRunning)
  #expect(model.failure == nil)
  #expect(model.actionableCandidates.count == 2)
  #expect(model.preview == nil)
  model.section = "Dreams"
  await model.loadCandidates()
  await model.showPreview(try #require(model.candidates.first))
  #expect(model.preview != nil)
  try fixture.append(dreamUser("u2", nil, dreamOld, "Keep C.") + "\n")
  _ = try transactionCompleted(
    fixture.store().run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  await model.refresh()
  #expect(model.actionableCandidates.count == 3)
  #expect(model.preview == nil)
  let first = try #require(model.actionableCandidates.first)
  await model.disposition(first, isRejected: true)
  let second = try #require(model.actionableCandidates.first)
  await model.disposition(second, isRejected: false)
  #expect(model.actionableCandidates.count == 2)
  #expect(model.actionableCandidates.contains { $0.disposition == .deferred })
  #expect(model.reviewedCandidates.count == 1)
  #expect(model.reviewedCandidates.first?.disposition == .rejected)
  let blocked = MemoryReviewCandidate(
    change: first.change, disposition: .blocked, limitation: "Synthetic conflict",
    frozenLimitations: [])
  model.candidates.append(blocked)
  #expect(model.actionableCandidates.count == 2)
  #expect(model.blockedCandidates.count == 1)
  #expect(model.reviewedCandidates.count == 1)
  try await model.shutdown()
}
