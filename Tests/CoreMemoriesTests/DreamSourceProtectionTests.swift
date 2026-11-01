import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [
  "blocked", "wrongPolicy", "wrongID", "wrongInput", "wrongOutput", "wrongInvocation", "cancel",
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
  case "wrongPolicy": reply["policy"] = "foreign"
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

@Test(arguments: ["owner", "locator", "ownerBlocked", "approved"])
func sourceProtectionChangedRawOrAuthorityBytesBlockBeforeFreeze(target: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: [
    target == "source" ? "SYNTHETIC_SECRET preference." : "Use green buttons."
  ])
  var start = workerStart(fixture)
  if target == "approved" {
    let document = fixture.memory.appendingPathComponent("MEMORY.md")
    let before = try String(contentsOf: document, encoding: .utf8)
    try fixture.write(before + "\nSYNTHETIC_SECRET approved authority.\n", file: document)
    let git = Git(repo: fixture.memory, environment: [:])
    _ = try git.data(["add", "MEMORY.md"])
    _ = try git.data(["commit", "-m", "Synthetic authority"], additions: Git.proposalIdentity)
  }
  if target != "approved" {
    let owner = fixture.root.appendingPathComponent("AGENTS.md")
    if target == "locator" {
      try fixture.write("Follow owner-policy.md.\n", file: owner)
      try fixture.write(
        "SYNTHETIC_SECRET owner policy.", file: fixture.root.appendingPathComponent("owner-policy.md"))
    } else {
      try fixture.write("SYNTHETIC_SECRET owner policy.", file: owner)
    }
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
    if isTarget, target != "approved" {
      let reference = target == "locator" ? "owner-policy.md (" : "AGENTS.md ("
      #expect(pieces.contains { $0.hasPrefix(reference) })
    }
    if isTarget, target == "ownerBlocked" {
      try worker.send([
        "version": 1, "type": "sourceProtectionResult", "invocationID": frame["invocationID"]!,
        "requestID": frame["requestID"]!, "inputDigest": frame["inputDigest"]!,
        "status": "blocked", "code": "unavailable",
      ])
    } else {
      try worker.send(
        workerProtectionReply(
          frame,
          pieces: pieces.map {
            $0.replacingOccurrences(of: "SYNTHETIC_SECRET", with: "[x]")
          }))
    }
    if isTarget { break }
  }
  let final = try worker.frame()
  #expect(final["status"] as? String == "blocked")
  #expect(
    final["reason"] as? String
      == (target == "ownerBlocked" ? "sourceProtection:blocked" : "sourceProtection:changed"))
  try worker.finish()
  #expect(try fixture.protectedState() == originals)
  let state = try fixture.snapshot(fixture.state)
  #expect(
    !state.keys.contains {
      $0.hasSuffix("input.json") || $0.hasSuffix("context.json") || $0.hasSuffix("request.json")
    })
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
      #expect(frame["status"] as? String == "completed")
      break
    }
    if frame["type"] as? String == "modelRequest" {
      try worker.send(workerReply(frame, text: workerDecision(frame)))
      continue
    }
    try #require(frame["type"] as? String == "sourceProtectionRequest")
    try worker.send(workerProtectionReply(frame))
  }
  try worker.finish()
  #expect(
    (try fixture.snapshot(fixture.state)).values.allSatisfy {
      !String(decoding: $0.bytes, as: UTF8.self).contains("SYNTHETIC_PROTECTED_BODY")
    })
}

@Test func sourceProtectionReadResultCannotRenameItsToolToBypassCallProvenance() throws {
  let call: [String: Any] = [
    "message": [
      "role": "assistant",
      "content": [
        [
          "type": "toolCall", "id": "protected", "name": "read", "arguments": ["path": ".env"],
        ]
      ],
    ]
  ]
  let result: [String: Any] = [
    "message": [
      "role": "toolResult", "toolCallId": "protected", "toolName": "other",
      "content": "SYNTHETIC_BODY",
    ]
  ]
  #expect(throws: DreamSourceProtectionError.blocked) {
    try DreamSourceProtection.requireAdmissibleReadProvenance([call, result])
  }
}
