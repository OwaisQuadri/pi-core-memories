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
func nativeStatusKeepsTechnicalDetailsOutOfThePrimaryExplanation(_ reason: String) async throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (_, pending) = try savedRecoveryPendingAddition(fixture)
  let configuration = queueConfiguration(fixture)
  let detail = "Synthetic provider error: quota exceeded"
  _ = try savedNativeReport(
    configuration: configuration, runID: pending.runID, reason: reason, detail: detail)
  let url = fixture.root.appendingPathComponent("profile/config.json")
  try configuration.save(to: url)
  let before = try fixture.snapshot(fixture.root)
  let model = AppModel(configURL: url)
  await model.load()
  #expect(!model.dreamDetail.isEmpty)
  #expect(!model.dreamDetail.contains(detail))
  #expect(model.invocationStatus?.detail == detail)
  #expect(try fixture.snapshot(fixture.root) == before)
  try await model.shutdown()
}

private func savedNativeReport(
  configuration: MemoryConfiguration, runID: String,
  reason: String = "staleUnpublishedPlans", detail: String = ""
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
      "status": "pending", "reason": reason, "runID": runID, "detail": detail,
    ]), name: "event-1.json")
  return URL(fileURLWithPath: configuration.diagnostics).appendingPathComponent(name)
}
