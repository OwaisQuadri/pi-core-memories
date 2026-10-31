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

@Test func sourceProtectionManySnippetsAndOwnerLocatorsStayWithinTheRequestLimit() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  for index in 0..<4 {
    try fixture.write(
      "---\nname: s\(index)\n---\n\nSynthetic body \(index)\n",
      file: fixture.snippets.appendingPathComponent("s\(index).md"))
  }
  let owner = fixture.root.appendingPathComponent("AGENTS.md")
  var rules = "Global rules.\n"
  for name in ["code-style.md", "prompt-style.md", "a/SKILL.md", "b/SKILL.md", "c/SKILL.md"] {
    try fixture.write("Rule \(name)\n", file: fixture.root.appendingPathComponent(name))
    rules += "- instruction: \(name)\n"
  }
  try fixture.write(rules, file: owner)
  try fixture.populate()
  var start = workerStart(fixture)
  var roots = start["roots"] as! [String: Any]
  roots["globalAgents"] = owner.path
  start["roots"] = roots
  let worker = try DreamWorkerProcess()
  defer { worker.clean() }
  try worker.send(start)
  let request = try worker.frame()
  try #require(request["type"] as? String == "modelRequest", "\(request["reason"] ?? "")")
  #expect(worker.protectionCount < 16)
  try worker.send(workerReply(request, text: workerDecision(request)))
  let final = try worker.frame()
  #expect(final["status"] as? String == "completed")
  try worker.finish()
}

@Test(arguments: [6, 8, 16])
func sourceProtectionRequestBudgetDropsRelatedWindowsBeforeTheLimit(limit: Int) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  var budget = 16
  var used = 0
  var requests: [[String]] = []
  var prepared: PreparedSessionBatch?
  func check(_ pieces: [String]) throws -> [String] {
    used += 1
    guard used <= budget else { throw DreamSourceProtectionError.requestLimit }
    requests.append(pieces)
    return pieces
  }
  func run(_ call: (DreamModelRequest) throws -> DreamCompletedResponse) throws
    -> DreamTransactionResult
  {
    try fixture.store().run(
      selection: fixture.selection,
      sourceRoles: DreamSourceRoles(isSnippetsPresent: true, isPromptsPresent: false),
      protect: { _ = try check($0) }, remainingProtections: { budget - used },
      prepare: { progress, sources in
        let batch = try SessionReader(
          sessions: sources.sessions, snippets: sources.snippets, prompts: sources.prompts,
          environment: [:]
        ).prepareProtected(
          progress: progress, limits: DreamInputLimits(), protect: { _ = try check($0) },
          admit: check)
        prepared = batch
        return batch
      }, call: call)
  }
  _ = try run(transactionNotes)
  let related = try DreamSourceProtection.pieces(try #require(prepared))
  try fixture.append(dreamUser("u9", nil, dreamOld, "Prefer dark mode.") + "\n")
  budget = limit
  used = 0
  requests = []
  if limit == 6 {
    #expect(throws: DreamSourceProtectionError.requestLimit) { try run(transactionUncalled) }
    #expect(!requests.contains(related))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.state.appendingPathComponent("admissions/1.json").path))
  } else {
    var limitations: [String] = []
    let result = try run { request in
      limitations = try transactionObject(request)["limitations"] as! [String]
      return try transactionNotes(request)
    }
    guard case .completed = result else {
      Issue.record("related run did not complete")
      return
    }
    let isRelatedDropped = limit < 16
    #expect(requests.contains(related) != isRelatedDropped)
    #expect(
      limitations.contains(
        "A related retained window exceeded the source-check limit and was not supplied.")
        == isRelatedDropped)
  }
}
