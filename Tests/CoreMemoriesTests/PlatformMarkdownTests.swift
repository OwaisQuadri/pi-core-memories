import Foundation
import Testing

@testable import CoreMemories

private let observedBypasses = [
  (
    "Cited paragraph [source: owner; added: 2024-02-29]\n> Uncited paragraph\n",
    "line 2: missing or malformed [source: reference; added: YYYY-MM-DD]"
  ),
  (
    "[rule]: docs/owner.md Uncited fact\n",
    "line 1: missing or malformed [source: reference; added: YYYY-MM-DD]"
  ),
]

@Test func platformParagraphBoundariesRejectObservedBypasses() throws {
  let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: true)
  for (document, diagnostic) in observedBypasses {
    let parsed = try AttributedString(markdown: document, options: options)
    let identities = Set(
      parsed.runs.compactMap { run -> Int? in
        guard let intent = run.presentationIntent?.components.first,
          intent.kind == .paragraph
        else { return nil }
        return intent.identity
      })
    #expect(identities.count == (document.hasPrefix("Cited") ? 2 : 1))
    #expect(MemoryDocument.failures(in: Data(document.utf8)) == [diagnostic])
  }
}
