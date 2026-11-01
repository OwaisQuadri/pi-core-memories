import Foundation
import Testing

@testable import CoreMemories

private func admittedBatch(
  _ fixture: TransactionFixture, progress: DreamProgress = try! DreamProgress(),
  prior: [DreamAdmittedView] = [], replacement: String = "[x]",
  inspect: @escaping ([String]) -> Void = { _ in }
) throws -> PreparedSessionBatch {
  try SessionReader(sessions: fixture.sessions, snippets: fixture.snippets, environment: [:])
    .prepareProtected(
      progress: progress, limits: DreamInputLimits(), protect: { pieces in inspect(pieces) },
      admit: { pieces in
        inspect(pieces)
        return pieces.map { $0.replacingOccurrences(of: "SYNTHETIC_SECRET", with: replacement) }
      }, priorViews: prior)
}

@Test func admittedStrippingRootIsCheckedInOneRequestAndRedactsOnlyItsSecretFile() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let secret = "---\nname: secret\n---\n\nSYNTHETIC_SECRET body\n"
  let plain = "---\nname: plain\n---\n\nPlain body\n"
  try fixture.write(secret, file: fixture.snippets.appendingPathComponent("b.md"))
  try fixture.write(plain, file: fixture.snippets.appendingPathComponent("c.md"))
  let original = try String(
    contentsOf: fixture.snippets.appendingPathComponent("strip.md"), encoding: .utf8)
  var requests: [[String]] = []
  let batch = try admittedBatch(fixture, inspect: { requests.append($0) })
  let secretRequests = requests.filter { $0.contains(secret) }
  #expect(secretRequests.count == 1)
  #expect(secretRequests.first.map(Set.init) == [secret, plain, original])
  let stripping = Dictionary(
    uniqueKeysWithValues: try #require(batch.provenance?.stripping).map { ($0.name, $0) })
  let redacted = secret.replacingOccurrences(of: "SYNTHETIC_SECRET", with: "[x]")
  #expect(stripping["b.md"]?.bytes == Data(redacted.utf8))
  #expect(stripping["b.md"]?.originalHash == SourceDigest(bytes: Data(secret.utf8)))
  #expect(stripping["c.md"]?.bytes == Data(plain.utf8))
  #expect(stripping["strip.md"]?.bytes == Data(original.utf8))
}

@Test func admittedViewWorkerFreezesSanitizedBytesAndReplaysExactRequestAcrossRestart() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["SYNTHETIC_SECRET durable preference."])
  let original = try fixture.protectedState()
  let first = try DreamWorkerProcess()
  defer { first.clean() }
  first.protectionTransform = {
    $0.map { $0.replacingOccurrences(of: "SYNTHETIC_SECRET", with: "[x]") }
  }
  try first.send(workerStart(fixture))
  let request = try first.frame()
  try #require(request["type"] as? String == "modelRequest")
  #expect(!String(describing: request).contains("SYNTHETIC_SECRET"))
  try first.send(workerReply(request, category: "cancelled"))
  #expect(try first.frame()["status"] as? String == "pending")
  try first.finish()
  let frozen = try fixture.snapshot(fixture.state.appendingPathComponent("runs"))
  #expect(
    frozen.values.allSatisfy {
      !String(decoding: $0.bytes, as: UTF8.self).contains("SYNTHETIC_SECRET")
    })
  let second = try DreamWorkerProcess()
  defer { second.clean() }
  try second.send(workerStart(fixture, resume: "retryInterruptedCall"))
  let retry = try second.frame()
  try #require(retry["type"] as? String == "modelRequest")
  #expect(retry["requestHash"] as? String == request["requestHash"] as? String)
  #expect(
    try JSONSerialization.data(withJSONObject: retry["messages"]!)
      == JSONSerialization.data(withJSONObject: request["messages"]!))
  try second.send(workerReply(retry, text: workerDecision(retry)))
  #expect(try second.frame()["status"] as? String == "completed")
  try second.finish()
  #expect(try fixture.protectedState() == original)
  try fixture.append(dreamUser("u2", nil, dreamOld, "Another preference.") + "\n")
  let third = try DreamWorkerProcess()
  defer { third.clean() }
  try third.send(workerStart(fixture))
  let appended = try third.frame()
  try #require(appended["type"] as? String == "modelRequest")
  #expect(!String(describing: appended).contains("SYNTHETIC_SECRET"))
  try third.send(workerReply(appended, text: workerDecision(appended)))
  #expect(try third.frame()["generation"] as? String == "2")
  try third.finish()
}
