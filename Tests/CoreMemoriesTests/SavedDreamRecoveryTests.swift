import Foundation
import Testing

@testable import CoreMemories

func savedRun(_ fixture: TransactionFixture) throws -> (runID: String, approvedBase: String) {
  let admission = try DreamRunEncoding.decode(
    DreamRunEncoding.Admission.self,
    bytes: Data(contentsOf: fixture.state.appendingPathComponent("admissions/0.json")))
  return (admission.runID, admission.base)
}

func savedRecoveryPendingAddition(_ fixture: TransactionFixture) throws
  -> (DreamRunStore, (runID: String, approvedBase: String))
{
  try fixture.populate()
  let store = try fixture.store()
  store.beforePublication = { _ in throw CancellationError() }
  #expect(throws: CancellationError.self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) })
  }
  try fixture.advance()
  return (store, try savedRun(fixture))
}

@Test func savedRecoveryOutsideMainAdvanceRequiresFreshPreviewAndExplicitEntryApproval() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (store, pending) = try savedRecoveryPendingAddition(fixture)
  let before = try fixture.protectedState()
  let recovery = try store.previewSavedRecovery(runID: pending.runID)
  #expect(recovery.suggestions.count == 1)
  #expect(recovery.suggestions[0].blocker == nil)
  #expect(try fixture.protectedState() == before)
  _ = try transactionCompleted(store.confirmSavedRecovery(recovery))
  #expect(try fixture.protectedState() == before)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: store, environment: [:])
  let candidate = try #require(controller.list().first)
  #expect(candidate.disposition == .pending)
  try controller.confirmDetach(controller.checkoutPreview())
  let old = try controller.preview(candidateID: candidate.change.id, clockDate: Date())
  let git = Git(repo: fixture.memory, environment: [:])
  let base = try fixture.main()
  let management = try MemoryManagement(repository: fixture.memory, environment: [:]).execute(
    .init(operation: .add, base: base, path: "MEMORY.md",
      replacement: "Keep unrelated management memory. [source: fixture; added: 2026-01-01]",
      reason: "Explicit unrelated management addition"))
  let advanced = try #require(management.commit)
  #expect(throws: (any Error).self) { try controller.apply(old) }
  let fresh = try controller.preview(candidateID: candidate.change.id, clockDate: Date())
  #expect(try fixture.main() == advanced)
  #expect(String(decoding: fresh.replacement, as: UTF8.self).contains("Keep unrelated management memory."))
  let approval = try controller.apply(fresh)
  #expect(try fixture.main() == approval.commit)
  let later = try git.text(
    ["commit-tree", "-p", approval.commit, "-m", "Later management", "\(approval.commit)^{tree}"],
    additions: Git.proposalIdentity)
  _ = try git.data(["update-ref", "refs/heads/main", later, approval.commit])
  #expect(try controller.list().first?.disposition == .approved)
}

@Test func savedRecoveryPublishesOnlyMissingOriginalRefsIncludingAbsentProjectMemory() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let project = fixture.root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
  _ = try Git(repo: project, environment: [:]).data(["init", "--template="])
  try fixture.populate(cwd: project.path)
  let store = try fixture.store()
  store.beforePublication = { path in
    if path.hasPrefix("projects/") { throw CancellationError() }
  }
  #expect(throws: CancellationError.self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0, isProject: true) })
  }
  let originalReceipts = try fixture.snapshot(fixture.payload("receipts"))
  let originalArtifacts = try ["input.json", "context.json", "request.json", "response.json", "decisions.json"]
    .map { try Data(contentsOf: fixture.payload($0)) }
  let originalBase = try fixture.main()
  try fixture.advance()
  let pending = try savedRun(fixture)
  let preview = try store.previewSavedRecovery(runID: pending.runID)
  #expect(preview.suggestions.count == 2)
  #expect(preview.suggestions.allSatisfy { $0.blocker == nil })
  let report = try transactionCompleted(store.confirmSavedRecovery(preview))
  #expect(report.proposals.count == 2)
  for receipt in report.proposals {
    #expect(receipt.base == originalBase)
    #expect(try Git(repo: fixture.memory, environment: [:]).text([
      "rev-parse", "\(receipt.commit)^",
    ]) == originalBase)
  }
  let receipts = try fixture.snapshot(fixture.payload("receipts"))
  for (path, value) in originalReceipts { #expect(receipts[path] == value) }
  #expect(try ["input.json", "context.json", "request.json", "response.json", "decisions.json"]
    .map { try Data(contentsOf: fixture.payload($0)) } == originalArtifacts)
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: store, environment: [:])
  let projectCandidate = try #require(controller.list().first { $0.change.path.hasPrefix("projects/") })
  #expect(projectCandidate.disposition == .pending)
  try controller.confirmDetach(controller.checkoutPreview())
  let entry = try controller.preview(candidateID: projectCandidate.change.id, clockDate: Date())
  #expect(entry.before.isEmpty)
  _ = try controller.apply(entry)
}

@Test func savedRecoveryRetainsAndReverifiesTheActiveReplacementLineage() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  let store = try fixture.store()
  _ = try transactionPending(store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { _ in try DreamCompletedResponse(text: "Invalid saved reply") }), reason: .invalidDecision)
  store.beforePublication = { _ in throw CancellationError() }
  #expect(throws: CancellationError.self) {
    try store.run(
      selection: fixture.selection, resume: .replaceInvalidResponse,
      prepare: transactionUncalledPrepare, call: { try transactionAdd($0) })
  }
  try fixture.advance()
  let pending = try savedRun(fixture)
  let names = ["response.json", "rejected-1.json", "replacement-1.json", "replacement-1-response.json"]
  let before = try names.map { try Data(contentsOf: fixture.payload($0)) }
  _ = try transactionCompleted(store.confirmSavedRecovery(store.previewSavedRecovery(runID: pending.runID)))
  #expect(try names.map { try Data(contentsOf: fixture.payload($0)) } == before)
  #expect(try store.verifiedCompletedReviewCandidates().flatMap(\.changes).count == 1)
  try Data("Changed archive".utf8).write(to: fixture.payload("rejected-1.json"))
  #expect(throws: (any Error).self) { try store.verifiedCompletedReviewCandidates() }
}

@Test func savedRecoveryRejectsCrossStoreCrossRunConsumedAndStaleConfirmations() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (store, pending) = try savedRecoveryPendingAddition(fixture)
  let preview = try store.previewSavedRecovery(runID: pending.runID)
  #expect(throws: (any Error).self) { try fixture.store().confirmSavedRecovery(preview) }
  #expect(throws: (any Error).self) {
    try store.previewSavedRecovery(runID: UUID().uuidString.lowercased())
  }
  #expect(throws: (any Error).self) { try store.confirmSavedRecovery(preview) }
  let stale = try store.previewSavedRecovery(runID: pending.runID)
  try fixture.advance()
  #expect(throws: (any Error).self) { try store.confirmSavedRecovery(stale) }
  #expect(try Git(repo: fixture.memory, environment: [:]).text([
    "for-each-ref", "--format=%(refname)", "refs/heads/proposals/",
  ]).isEmpty)
  let fresh = try store.previewSavedRecovery(runID: pending.runID)
  _ = try transactionCompleted(store.confirmSavedRecovery(fresh))
  #expect(throws: (any Error).self) { try store.confirmSavedRecovery(fresh) }
}

@Test(arguments: ["before-checkpoint", "after-checkpoint", "receipt", "completion", "after-completion", "generation", "after-generation"])
func savedRecoveryInterruptionNeverFallsThroughToOrdinaryPropose(_ boundary: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (store, pending) = try savedRecoveryPendingAddition(fixture)
  let decisions = try DreamRunEncoding.decode(
    DreamRunEncoding.Decisions.self, bytes: Data(contentsOf: fixture.payload("decisions.json")))
  let receipt = SourceDigest(bytes: try DreamRunEncoding.encode(decisions.plans[0])).rawValue + ".json"
  let preview = try store.previewSavedRecovery(runID: pending.runID)
  let event: DreamPersistenceEvent
  switch boundary {
  case "before-checkpoint": event = .beforeInstall("recovery.json")
  case "after-checkpoint": event = .afterInstall("recovery.json")
  case "receipt": event = .beforeInstall(receipt)
  case "completion": event = .beforeInstall("completion.json")
  case "after-completion": event = .afterInstall("completion.json")
  case "generation": event = .beforeInstall("1.json")
  default: event = .afterInstall("1.json")
  }
  store.persistenceFault = { if $0 == event { throw POSIXError(.EIO) } }
  let before = try fixture.protectedState()
  #expect(throws: DreamRunError.persistenceFailure) { try store.confirmSavedRecovery(preview) }
  #expect(try fixture.protectedState() == before)
  if boundary == "after-checkpoint" {
    _ = try Git(repo: fixture.memory, environment: [:]).data([
      "update-ref", "refs/heads/main", pending.approvedBase,
    ])
  }
  let resumedBefore = try fixture.protectedState()
  let reopened = try fixture.store()
  reopened.beforePublication = { _ in Issue.record("recovery must never call ordinary propose") }
  let resumed = try reopened.run(
    selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  if boundary == "before-checkpoint" {
    let dropped = try transactionPending(resumed, reason: .droppedBatch)
    #expect(dropped.proposals.isEmpty)
    #expect(throws: (any Error).self) { try reopened.previewSavedRecovery(runID: pending.runID) }
    #expect(try fixture.protectedState() == resumedBefore)
    return
  }
  if boundary == "after-checkpoint" {
    _ = try transactionPending(resumed, reason: .staleUnpublishedPlans)
    let confirmed = try reopened.previewSavedRecovery(runID: pending.runID)
    _ = try transactionCompleted(reopened.confirmSavedRecovery(confirmed))
  } else {
    #expect(try transactionCompleted(resumed).generation == 1)
  }
  let bundles = try reopened.verifiedCompletedReviewCandidates()
  #expect(bundles.count == 1)
  #expect(bundles[0].recoveryCheckpointHash != nil)
  #expect(bundles[0].recoveryCheckpoint != nil)
  #expect(try fixture.protectedState() == resumedBefore)
}

@Test(arguments: ["missing", "forged", "cross-run", "missing-ref", "mismatched-ref"])
func savedRecoveryCompletedProofRefusesChangedCheckpointAndReceiptedRefs(_ variant: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let (store, pending) = try savedRecoveryPendingAddition(fixture)
  let report = try transactionCompleted(
    store.confirmSavedRecovery(store.previewSavedRecovery(runID: pending.runID)))
  let file = try fixture.payload("recovery.json")
  if variant == "missing" {
    try FileManager.default.removeItem(at: file)
  } else if variant == "forged" || variant == "cross-run" {
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    object[variant == "forged" ? "frozenProofHash" : "runID"] =
      variant == "forged" ? String(repeating: "0", count: 64) : UUID().uuidString.lowercased()
    try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
  } else {
    let git = Git(repo: fixture.memory, environment: [:])
    _ = try git.data(variant == "missing-ref"
      ? ["update-ref", "-d", report.proposals[0].ref]
      : ["update-ref", report.proposals[0].ref, fixture.main()])
  }
  let before = try fixture.protectedState()
  #expect(throws: (any Error).self) { try fixture.store().verifiedCompletedReviewCandidates() }
  #expect(try fixture.protectedState() == before)
}

@Test(arguments: ["moved", "metadata", "duplicate", "contradiction", "scope", "nil-identity", "ambiguous-nil", "forged-approval"])
func savedRecoveryExactTargetsBlockOnlyAffectedEntries(_ variant: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let identity = "11111111-1111-1111-1111-111111111111"
  let metadata = " [memory-id: \(identity); reviewed: 2026-01-01T00:00:00Z]"
  let blue = "Use blue buttons. [source: pi:one#old/part/0; added: 2026-01-01]"
    + (["nil-identity", "ambiguous-nil"].contains(variant) ? "" : metadata) + "\n"
  let anchor = "Keep exact contrast. [source: pi:one#contrast/part/0; added: 2026-01-01]\n"
  let original = "# Memory\n\n" + blue + "\n" + anchor
  let file = fixture.memory.appendingPathComponent("MEMORY.md")
  try fixture.write(original, file: file)
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "MEMORY.md"])
  _ = try git.data(["commit", "-m", "Original anchors"], additions: Git.proposalIdentity)
  try fixture.populate()
  let store = try fixture.store()
  store.beforePublication = { _ in throw CancellationError() }
  #expect(throws: CancellationError.self) {
    try store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) }, call: { request in
        let context = try transactionObject(request)
        let anchors = context["eligibleMemoryAnchors"] as! [[String: Any]]
        let source = (context["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        return try transactionResponse(request, decisions: [
          ["kind": "update", "scope": ["kind": "global"], "anchor": anchors[0],
           "text": "Use green buttons.", "sources": [source], "reason": "Apply correction.",
           "contradictions": [
             ["kind": "memory", "anchor": anchors[0], "explanation": "Replace blue."],
             ["kind": "memory", "anchor": anchors[1], "explanation": "Keep contrast."],
           ]],
          ["kind": "add", "scope": ["kind": "global"], "text": "Keep keyboard access.",
           "sources": [source], "reason": "Retain access.", "contradictions": []],
        ])
      })
  }
  var current = "# Memory\n\n" + anchor + "\n" + blue
  switch variant {
  case "metadata": current = current.replacingOccurrences(of: "2026-01-01T00:00:00Z", with: "2026-01-02T00:00:00Z")
  case "ambiguous-nil": current += "\n" + blue
  case "duplicate":
    let key = String(repeating: "b", count: 64)
    try fixture.write("# Memory\n\n" + blue, file: fixture.memory.appendingPathComponent("projects/\(key).md"))
  case "contradiction": current = current.replacingOccurrences(of: "Keep exact contrast.", with: "Change contrast.")
  case "scope":
    let key = String(repeating: "a", count: 64)
    try fixture.write("# Memory\n\n" + blue, file: fixture.memory.appendingPathComponent("projects/\(key).md"))
    current = "# Memory\n\n" + anchor
  default: break
  }
  try fixture.write(current, file: file)
  _ = try git.data(["add", "."])
  _ = try git.data(["commit", "-m", "Outside anchor movement"], additions: Git.proposalIdentity)
  let pending = try savedRun(fixture)
  let preview = try store.previewSavedRecovery(runID: pending.runID)
  let isCompatible = ["moved", "nil-identity", "forged-approval"].contains(variant)
  #expect(preview.suggestions.filter { $0.blocker == nil }.count == (isCompatible ? 2 : 1))
  _ = try transactionCompleted(store.confirmSavedRecovery(preview))
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
    sources: store, environment: [:])
  let rows = try controller.list()
  let update = try #require(rows.first { $0.change.operation == .update })
  #expect(update.disposition == (isCompatible ? .pending : .blocked))
  #expect(rows.first { $0.change.operation == .add }?.disposition == .pending)
  if isCompatible {
    try controller.confirmDetach(controller.checkoutPreview())
    let entry = try controller.preview(candidateID: update.change.id, clockDate: Date())
    #expect(entry.before == Data(blue.utf8))
    if variant == "forged-approval" {
      let store = try MemoryStore(repo: fixture.memory, environment: [:])
      let changed = Data(current.replacingOccurrences(of: "Keep exact contrast.", with: "Change exact contrast.").utf8)
      let historical = try store.reviewCommit(
        base: entry.currentBase, path: "MEMORY.md", replacement: changed, message: Data("Outside anchor change\n".utf8))
      let target = try #require(MemoryDocument.entries(in: changed).first { $0.identity?.uuidString.lowercased() == identity })
      var replacement = changed
      replacement.replaceSubrange(target.locator.start..<target.locator.end, with: entry.after)
      let admission = try Data(contentsOf: fixture.root.appendingPathComponent("review/candidate-\(update.change.id.rawValue).json"))
      let payload = ReviewPreviewPayload(
        candidateID: update.change.id.rawValue, admissionHash: SourceDigest(bytes: admission).rawValue,
        frozenBase: update.change.base, currentBase: historical, path: update.change.path,
        identity: entry.identity, instant: entry.instant, start: target.locator.start,
        end: target.locator.end, before: target.bytes, after: entry.after,
        originalDocument: changed, replacement: replacement,
        checkout: try store.reviewGit.reviewCheckout().witness())
      let payloadBytes = try MemoryReviewEncoding.encode(payload)
      let hash = SourceDigest(bytes: payloadBytes).rawValue
      let commit = try store.reviewCommit(
        base: historical, path: payload.path, replacement: replacement,
        message: Data("Core memory native review\n\n".utf8) + payloadBytes + Data("\n".utf8))
      let attempt = ReviewAttempt(
        schemaVersion: 1, preview: payload, previewHash: hash, resultCommit: commit,
        resultTree: try git.text(["rev-parse", "\(commit)^{tree}"]),
        auditRef: "refs/memory-review/approvals/\(hash)")
      let directory = try DreamStateDirectory.openRoot(fixture.root.appendingPathComponent("review"))
      try directory.installReviewFile(MemoryReviewEncoding.encode(attempt), name: "attempt-\(hash).json")
      _ = try git.data(["update-ref", attempt.auditRef, commit])
      #expect(throws: (any Error).self) { try controller.list() }
    } else {
      let approval = try controller.apply(entry)
      let changed = Data(String(decoding: entry.replacement, as: UTF8.self)
        .replacingOccurrences(of: "Keep exact contrast.", with: "Change exact contrast.").utf8)
      let historical = try MemoryStore(repo: fixture.memory, environment: [:]).reviewCommit(
        base: approval.commit, path: "MEMORY.md", replacement: changed, message: Data("Later anchor change\n".utf8))
      _ = try git.data(["update-ref", "refs/heads/main", historical, approval.commit])
      #expect(try controller.list().first { $0.change.id == update.change.id }?.disposition == .approved)
    }
  }
}
