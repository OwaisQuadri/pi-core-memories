import Foundation
import Testing

@testable import CoreMemories

@Test func atomicChangesKeepIndividualFrozenSourcesBeforeFileConsolidation() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Use green buttons.", "Use large buttons."])
  let store = try fixture.store()
  _ = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let bundle = try #require(store.verifiedCompletedReviewCandidates().first)
  #expect(bundle.receipts.count == 1)
  #expect(bundle.changes.count == 2)
  #expect(Set(bundle.changes.map(\.id)).count == 2)
  #expect(
    bundle.changes.map { $0.sources[0].exactText } == ["Use green buttons.", "Use large buttons."])
  for change in bundle.changes {
    #expect(change.operation == .add)
    #expect(change.locator == nil)
    #expect(change.before == nil)
    #expect(change.entryID == nil)
    #expect(change.reason == "Retain the preference.")
    #expect(change.contradictions.isEmpty)
    #expect(String(decoding: change.after, as: UTF8.self).contains("[source: pi:one#"))
    #expect(!String(decoding: change.after, as: UTF8.self).contains("memory-id:"))
    #expect(MemoryDocument.entries(in: change.after).filter(\.isMutable).count == 1)
  }
  let reopened = try fixture.store().verifiedCompletedReviewCandidates()
  #expect(reopened[0].changes.map(\.id) == bundle.changes.map(\.id))
  let decisions = try Data(contentsOf: fixture.payload("decisions.json"))
  let object = try JSONSerialization.jsonObject(with: decisions) as! [String: Any]
  #expect(object["atomicChanges"] == nil)
  #expect((object["plans"] as! [Any]).count == 1)
}

@Test func atomicUpdateKeepsExactLegacyAnchorAndStructuredContradiction() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let paragraph = "同じ 🌱 [source: owner; added: 2024-02-29]\r\n"
  try fixture.write(
    "# Memory\r\n\r\n" + paragraph, file: fixture.memory.appendingPathComponent("MEMORY.md"))
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "MEMORY.md"])
  _ = try git.data(["commit", "-m", "Synthetic legacy memory"], additions: Git.proposalIdentity)
  try fixture.populate()
  let store = try fixture.store()
  _ = try transactionCompleted(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let object = try transactionObject(request)
        let source = (object["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        let anchor = (object["eligibleMemoryAnchors"] as! [[String: Any]])[0]
        return try transactionResponse(
          request,
          decisions: [
            [
              "kind": "update", "scope": ["kind": "global"], "anchor": anchor,
              "text": "Use green buttons.", "reason": "Replace the old preference.",
              "sources": [source],
              "contradictions": [
                ["kind": "memory", "anchor": anchor, "explanation": "Old preference."]
              ],
            ]
          ])
      }))
  let change = try #require(store.verifiedCompletedReviewCandidates().first?.changes.first)
  #expect(change.operation == .update)
  #expect(change.before == Data(paragraph.utf8))
  #expect(change.entryID == nil)
  #expect(change.locator?.start == Data("# Memory\r\n\r\n".utf8).count)
  #expect(change.after.suffix(2) == Data("\r\n".utf8))
  guard case .memory(let anchor, let explanation) = change.contradictions[0] else {
    Issue.record("missing structured memory contradiction")
    return
  }
  #expect(Data(anchor.before.utf8) == change.before)
  #expect(explanation == "Old preference.")
}

@Test(arguments: [false, true])
func atomicUpdateCannotEraseMalformedOrDuplicateIdentity(isDuplicate: Bool) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let metadata =
    isDuplicate
    ? "[memory-id: 11111111-2222-3333-4444-555555555555; reviewed: 2026-07-10T12:30:00Z]"
    : "[memory-id: bad; reviewed: bad]"
  let paragraph = "Memory [source: owner; added: 2024-02-29] " + metadata + "\n"
  try fixture.write(
    paragraph + (isDuplicate ? "\n" + paragraph : ""),
    file: fixture.memory.appendingPathComponent("MEMORY.md"))
  let git = Git(repo: fixture.memory, environment: [:])
  _ = try git.data(["add", "MEMORY.md"])
  _ = try git.data(["commit", "-m", "Synthetic invalid identity"], additions: Git.proposalIdentity)
  try fixture.populate()
  let store = try fixture.store()
  let before = try fixture.main()
  _ = try transactionPending(
    store.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { request in
        let object = try transactionObject(request)
        let source = (object["primaryEvidence"] as! [[String: Any]])[0]["source"]!
        let anchor = (object["eligibleMemoryAnchors"] as! [[String: Any]])[0]
        return try transactionResponse(
          request,
          decisions: [
            [
              "kind": "update", "scope": ["kind": "global"], "anchor": anchor,
              "text": "New preference.", "reason": "Replace the old preference.",
              "sources": [source],
              "contradictions": [
                ["kind": "memory", "anchor": anchor, "explanation": "Old preference."]
              ],
            ]
          ])
      }), reason: .invalidDecision)
  #expect(try fixture.main() == before)
}
