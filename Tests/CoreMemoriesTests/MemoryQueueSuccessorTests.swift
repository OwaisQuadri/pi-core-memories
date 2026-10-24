import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [
  "valid", "copied", "absent", "wrong-predecessor", "stale-claim", "unchanged", "uncovered",
  "disjoint-wrong",
])
func queueSuccessorRequiresVersionedChangedSourceBoundProofAndDoesNotResetRejection(mode: String)
  throws
{
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Prefer green buttons."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let queue = try queueFixture(fixture, sources: sources)
  let request = try MemoryQueueRequest(sessionID: "session", requestID: "reject")
  let original = try #require(queue.list(request: request).first)
  let display = try queue.claim(revision: original.finding.revision, request: request)
  try queue.presented(display, messageReference: "shown")
  _ = try queue.decide(display, action: "reject", decisionID: "reject", responseReference: "human")
  let other = try TransactionFixture()
  defer { other.clean() }
  try other.populate(texts: [
    "Prefer green buttons.",
    mode == "copied" ? "Prefer green buttons." : "Use blue buttons when printing; green otherwise.",
  ])
  let otherSources = try other.store()
  _ = try transactionCompleted(
    otherSources.run(
      selection: other.selection, prepare: { try other.prepare($0) },
      call: { modelRequest in
        let context = try transactionObject(modelRequest)
        let evidence = context["primaryEvidence"] as! [[String: Any]]
        let new = evidence[1]
        var decision: [String: Any] = [
          "kind": "add", "scope": ["kind": "global"],
          "text": mode == "unchanged"
            ? "Use green buttons." : "Use blue buttons when printing; green otherwise.",
          "sources": mode == "disjoint-wrong" ? [new["source"]!] : evidence.map { $0["source"]! },
          "contradictions": [],
          "reason": "Preserve the newly observed print condition.",
        ]
        if mode != "absent" {
          decision["successor"] = [
            "version": 1,
            "predecessorRevision": ["wrong-predecessor", "disjoint-wrong"].contains(mode)
              ? String(repeating: "0", count: 64) : original.finding.revision,
            "priorClaim": mode == "stale-claim"
              ? "wrong bytes" : String(decoding: original.finding.proposed, as: UTF8.self),
            "newEvidence": [["source": new["source"]!, "contentDigest": new["contentDigest"]!]],
            "explanation":
              "The prior green preference now has an explicit print exception, supported by the new source.",
          ]
        }
        let unused: [[String: Any]] =
          mode == "disjoint-wrong"
          ? [
            [
              "kind": "noChange", "sources": [evidence[0]["source"]!], "reasonCode": "notDurable",
              "explanation": "Not used in this finding.",
            ]
          ] : []
        return try transactionResponse(modelRequest, decisions: [decision] + unused)
      }))
  let otherRows: [MemoryReviewCandidate]
  do {
    let review = try MemoryReviewController(
      repository: other.memory, stateRoot: other.root.appendingPathComponent("review"),
      sources: otherSources, environment: [:])
    otherRows = try review.list()
  }
  let later = try MemoryQueueRequest(sessionID: "later", requestID: "later")
  let imported: [MemoryQueueRow]
  do {
    let review = try queue.controller()
    if mode == "uncovered" {
      let extra = try #require(otherRows.first)
      try queue.ledger(review) { state in
        var prior =
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.finding))
          as! [String: Any]
        prior["revision"] = String(repeating: "e", count: 64)
        prior["candidateID"] = String(repeating: "e", count: 64)
        prior["findingID"] = String(repeating: "e", count: 64)
        prior["claimDigest"] = String(repeating: "f", count: 64)
        prior["evidence"] = try JSONSerialization.jsonObject(
          with: JSONEncoder().encode([MemoryQueueEvidence(extra.change.sources[1])]))
        let independent = try JSONDecoder().decode(
          MemoryQueueFinding.self, from: JSONSerialization.data(withJSONObject: prior))
        state.findings.append(independent)
        let presentation = MemoryQueuePresentation(
          claimID: "independent", sequence: "1", request: later, finding: independent,
          previewDigest: "independent", currentBase: independent.frozenBase, before: Data(),
          after: independent.proposed, replacement: independent.proposed, isDetachRequired: false,
          checkoutCommit: independent.frozenBase, checkoutDigest: "independent")
        state.intents.append(
          QueueDecisionIntent(
            decisionID: "independent",
            display: MemoryQueueDisplay(presentation: presentation, displayDigest: "independent"),
            action: "reject", responseReference: "human"))
      }
    }
    imported = try queue.importCandidates(otherRows, review: review, request: later)
  }
  let successor = try #require(imported.first)
  #expect((successor.blockReason == nil) == (mode == "valid"))
  if mode == "valid" {
    #expect(successor.finding.suppressionEpoch == successor.finding.revision)
    #expect(successor.finding.successorRejections == [original.finding.revision])
    let review = try queue.controller()
    let repeated = try queue.importCandidates(otherRows, review: review, request: later)
    #expect(repeated.first?.finding == successor.finding)
    #expect(!MemoryQueue.isRepeatedSuccessor(original.finding, origin: successor.finding))
    try queue.ledger(review) { state in
      var prior =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.finding))
        as! [String: Any]
      var copied =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(successor.finding.evidence[1]))
        as! [String: Any]
      copied["entry"] = "old-copy"
      copied["identity"] = "old-copy-identity"
      prior["contradictions"] = [
        [
          "kind": "primary", "evidence": copied,
          "explanation": "Previously considered contrary evidence.",
        ]
      ]
      let old = try JSONDecoder().decode(
        MemoryQueueFinding.self, from: JSONSerialization.data(withJSONObject: prior))
      var historical = state
      historical.findings = [old]
      #expect(
        MemoryQueue.successorPredecessor(
          successor.finding, rejected: [old.revision], state: historical) == nil)
    }
    try queue.ledger(review) { state in
      let presentation = MemoryQueuePresentation(
        claimID: "successor", sequence: "1", request: later, finding: successor.finding,
        previewDigest: "successor", currentBase: successor.finding.frozenBase, before: Data(),
        after: successor.finding.proposed, replacement: successor.finding.proposed,
        isDetachRequired: false, checkoutCommit: successor.finding.frozenBase,
        checkoutDigest: "successor")
      state.intents.append(
        QueueDecisionIntent(
          decisionID: "reject-successor",
          display: MemoryQueueDisplay(presentation: presentation, displayDigest: "successor"),
          action: "reject", responseReference: "human"))
    }
    let rejected = try queue.importCandidates(
      otherRows, review: review,
      request: MemoryQueueRequest(sessionID: "later", requestID: "new-request"))
    #expect(rejected.first?.blockReason?.hasPrefix("blocked-successor:") == true)
  }
}
