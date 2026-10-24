import Foundation
import Testing

@testable import CoreMemories

@Test func sourceProtectionDigestBindsExactUTF8PieceBoundaries() throws {
  #expect(DreamSourceProtection.digest(["a", "bc"]) != DreamSourceProtection.digest(["ab", "c"]))
  #expect(DreamSourceProtection.digest(["é"]) != DreamSourceProtection.digest(["e\u{301}"]))
  #expect(throws: DreamSourceProtectionError.changed) {
    try DreamSourceProtection.requireUnchanged(["SYNTHETIC_SECRET"], ["[redacted]"])
  }
}

@Test(arguments: [
  "blocked", "changed", "wrongID", "wrongInput", "wrongOutput", "wrongInvocation", "cancel",
  "timeout",
])
func sourceProtectionFailureNeverFreezesInputOrDispatchesModel(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["SYNTHETIC_SECRET keep a preference."])
  let originals = try fixture.protectedState()
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  worker.isProtectingAutomatically = false
  try worker.send(workerStart(fixture))
  let request = try worker.frame()
  try #require(request["type"] as? String == "sourceProtectionRequest")
  let pieces = try #require(request["pieces"] as? [String])
  #expect(request["inputDigest"] as? String == DreamSourceProtection.digest(pieces).rawValue)
  var reply = workerProtectionReply(request)
  switch mode {
  case "blocked":
    reply = [
      "version": 1, "type": "sourceProtectionResult", "invocationID": request["invocationID"]!,
      "requestID": request["requestID"]!, "inputDigest": request["inputDigest"]!,
      "status": "blocked", "code": "unavailable",
    ]
  case "changed": reply = workerProtectionReply(request, pieces: pieces.map { $0 + "[redacted]" })
  case "wrongID": reply["requestID"] = "foreign"
  case "wrongInput": reply["inputDigest"] = String(repeating: "0", count: 64)
  case "wrongOutput": reply["outputDigest"] = String(repeating: "0", count: 64)
  case "wrongInvocation": reply["invocationID"] = "foreign"
  case "cancel": reply = ["version": 1, "type": "cancel", "invocationID": request["invocationID"]!]
  default: break
  }
  if mode != "timeout" { try worker.send(reply) }
  let final = try worker.frame()
  #expect(final["type"] as? String == "final")
  #expect(final["status"] as? String == "blocked")
  #expect(!String(describing: final).contains("SYNTHETIC_SECRET"))
  #expect(worker.progressFrames.allSatisfy { ($0["completedBytes"] as? Int ?? 0) == 0 })
  try worker.finish()
  #expect(try fixture.protectedState() == originals)
  let state = try fixture.snapshot(fixture.state)
  #expect(
    !state.keys.contains {
      $0.hasSuffix("input.json") || $0.hasSuffix("context.json") || $0.hasSuffix("request.json")
    })
  #expect(
    state.values.allSatisfy {
      !String(decoding: $0.bytes, as: UTF8.self).contains("SYNTHETIC_SECRET")
    })
}

@Test(arguments: ["source", "owner"])
func sourceProtectionChangedRawOrAuthorityBytesBlockBeforeFreeze(target: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: [
    target == "source" ? "SYNTHETIC_SECRET preference." : "Use green buttons."
  ])
  var start = workerStart(fixture)
  if target == "owner" {
    let owner = fixture.root.appendingPathComponent("AGENTS.md")
    try fixture.write("SYNTHETIC_SECRET owner policy.", file: owner)
    var roots = start["roots"] as! [String: Any]
    roots["globalAgents"] = owner.path
    start["roots"] = roots
  }
  let originals = try fixture.protectedState()
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  worker.isProtectingAutomatically = false
  try worker.send(start)
  while true {
    let frame = try worker.frame()
    try #require(frame["type"] as? String == "sourceProtectionRequest")
    let pieces = try #require(frame["pieces"] as? [String])
    let isTarget = pieces.contains { $0.contains("SYNTHETIC_SECRET") }
    try worker.send(
      workerProtectionReply(
        frame,
        pieces: pieces.map {
          $0.replacingOccurrences(of: "SYNTHETIC_SECRET", with: "[x]")
        }))
    if isTarget { break }
  }
  let final = try worker.frame()
  #expect(final["status"] as? String == "blocked")
  #expect(final["reason"] as? String == "sourceProtection:changed")
  try worker.finish()
  #expect(try fixture.protectedState() == originals)
  let state = try fixture.snapshot(fixture.state)
  #expect(
    !state.keys.contains {
      $0.hasSuffix("input.json") || $0.hasSuffix("context.json") || $0.hasSuffix("request.json")
    })
}

@Test func sourceProtectionLegacyRetryCannotRewriteOrRedispatchChangedSealedInput() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["SYNTHETIC_SECRET preference."])
  _ = try fixture.store().run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { _ in
      throw CancellationError()
    })
  let before = try fixture.snapshot(fixture.state)
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  worker.isProtectingAutomatically = false
  try worker.send(workerStart(fixture, resume: "retryInterruptedCall"))
  let frame = try worker.frame()
  try #require(frame["type"] as? String == "sourceProtectionRequest")
  let pieces = try #require(frame["pieces"] as? [String])
  #expect(pieces.contains { $0.contains("SYNTHETIC_SECRET") })
  try worker.send(
    workerProtectionReply(
      frame,
      pieces: pieces.map {
        $0.replacingOccurrences(of: "SYNTHETIC_SECRET", with: "[redacted]")
      }))
  let final = try worker.frame()
  #expect(final["status"] as? String == "blocked")
  try worker.finish()
  #expect(try fixture.snapshot(fixture.state) == before)
}

@Test(arguments: [".env", "auth.json", "credentials.md", "unknown"])
func sourceProtectionProtectedReadNeverSendsBodyToHostOrFreezesIt(path: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  if path != "unknown" {
    let call =
      "{\"type\":\"message\",\"id\":\"a1\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"read1\",\"name\":\"read\",\"arguments\":{\"path\":\"\(path)\"}}]}}"
    try fixture.append(call + "\n")
  }
  try fixture.append(
    "{\"type\":\"message\",\"id\":\"r1\",\"timestamp\":\"2026-01-01T00:00:01Z\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"read1\",\"toolName\":\"read\",\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"SYNTHETIC_PROTECTED_BODY\"}]}}\n"
  )
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  worker.isProtectingAutomatically = false
  try worker.send(workerStart(fixture))
  while true {
    let frame = try worker.frame()
    #expect(!String(describing: frame).contains("SYNTHETIC_PROTECTED_BODY"))
    if frame["type"] as? String == "final" {
      #expect(frame["status"] as? String == "blocked")
      break
    }
    try #require(frame["type"] as? String == "sourceProtectionRequest")
    try worker.send(workerProtectionReply(frame))
  }
  try worker.finish()
  #expect(!(try fixture.snapshot(fixture.state)).keys.contains { $0.hasSuffix("input.json") })
}
