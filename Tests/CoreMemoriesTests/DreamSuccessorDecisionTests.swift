import Foundation
import Testing

@testable import CoreMemories

@Test(arguments: [
  "valid", "null", "wrong-digest", "unknown-source", "wrong-version", "unknown-field",
])
func dreamSuccessorMetadataPinsSupportingPrimarySourceAndExactContentDigest(mode: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["New explicit print condition."])
  let store = try fixture.store()
  let result = try store.run(
    selection: fixture.selection, prepare: { try fixture.prepare($0) },
    call: { request in
      let context = try transactionObject(request)
      let evidence = (context["primaryEvidence"] as! [[String: Any]])[0]
      var source = evidence["source"] as! [String: Any]
      if mode == "unknown-source" { source["entry"] = "not-supplied" }
      var successor: [String: Any] = [
        "version": mode == "wrong-version" ? 2 : 1,
        "predecessorRevision": String(repeating: "a", count: 64),
        "priorClaim": "Prior exact annotated claim.\n",
        "newEvidence": [
          [
            "source": source,
            "contentDigest": mode == "wrong-digest"
              ? String(repeating: "b", count: 64) : evidence["contentDigest"]!,
          ]
        ], "explanation": "The new print condition changes the prior unconditional preference.",
      ]
      if mode == "unknown-field" { successor["approval"] = "approve" }
      return try transactionResponse(
        request,
        decisions: [
          [
            "kind": "add", "scope": ["kind": "global"], "text": "Use the print condition.",
            "sources": [evidence["source"]!], "contradictions": [],
            "reason": "Preserve the condition.", "successor": mode == "null" ? NSNull() : successor,
          ]
        ])
    })
  if ["valid", "null"].contains(mode) {
    _ = try transactionCompleted(result)
    let review = try MemoryReviewController(
      repository: fixture.memory, stateRoot: fixture.root.appendingPathComponent("review"),
      sources: store, environment: [:])
    let row = try #require(review.list().first)
    #expect((row.change.successor != nil) == (mode == "valid"))
  } else {
    _ = try transactionPending(result, reason: .invalidDecision)
  }
}
