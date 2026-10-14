import Foundation
import Testing

@testable import CoreMemories

@Test func approvedReviewDueUsesExactThirtyDaysUnknownAndFutureWithoutRevisionFallback() throws {
  let instant = "2026-01-01T00:00:00Z"
  let start = try #require(ISO8601DateFormatter().date(from: instant))
  #expect(!MemoryManagement.isReviewDue(instant, date: start.addingTimeInterval(30 * 86_400 - 1)))
  #expect(MemoryManagement.isReviewDue(instant, date: start.addingTimeInterval(30 * 86_400)))
  #expect(!MemoryManagement.isReviewDue(instant, date: start.addingTimeInterval(-1)))
  #expect(MemoryManagement.isReviewDue(nil, date: start))
}

@Test func approvedReviewCatalogExcludesHeadingsAndOtherProjectsButKeepsOldMemoriesInRender() throws
{
  let fixture = try Fixture()
  defer { fixture.clean() }
  let key = try #require(try MemoryStore.projectKey(cwd: fixture.repo))
  try fixture.write("# Memory\n\n" + fact("Global."), path: "MEMORY.md")
  try fixture.write("# Memory\n\n" + fact("Matching."), path: "projects/\(key).md")
  try fixture.write(
    "# Memory\n\n" + fact("Other."), path: "projects/" + String(repeating: "a", count: 64) + ".md")
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  let catalog = try manager.reviewCatalog(cwd: fixture.repo)
  #expect(catalog.entries.count == 2)
  #expect(catalog.entries.allSatisfy { MemoryManagement.isReviewDue($0.reviewed, date: Date()) })
  let rendered = try fixture.store.render(cwd: fixture.repo)
  #expect(
    rendered.contains("Global.") && rendered.contains("Matching.") && !rendered.contains("Other."))
}

@Test func approvedReviewChangesOnlyMetadataAndAdoptsLegacyIdentityWithCheckedPublication() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let old = fact("Exact café 🐟.").replacingOccurrences(of: "\n", with: "\r\n")
  let other = fact("Leave this alone.")
  try fixture.write("# Memory\n\n" + old + "\n" + other, path: "MEMORY.md")
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  let catalog = try manager.reviewCatalog(cwd: fixture.repo)
  let entry = try #require(catalog.entries.first)
  let before = try fixture.humanState()
  #expect(throws: (any Error).self) {
    try manager.confirmReviewed(base: catalog.base, entry: entry)
  }
  #expect(try fixture.humanState() == before)
  try manager.confirmDetach(manager.checkoutPreview())
  var checkout = try fixture.humanState()
  checkout.removeValue(forKey: "main")
  let date = try #require(ISO8601DateFormatter().date(from: "2026-06-01T12:30:00Z"))
  let receipt = try manager.confirmReviewed(base: catalog.base, entry: entry, date: date)
  let next = try manager.reviewCatalog(cwd: fixture.repo)
  let reviewed = next.entries[0]
  #expect(reviewed.reviewed == "2026-06-01T12:30:00Z")
  #expect(reviewed.revised == nil && reviewed.identity != nil)
  #expect(next.entries[1].expected == other)
  let expected = try MemoryDocument.reviewedBytes(
    Data(old.utf8), identity: reviewed.identity!,
    instant: MemoryDocument.ReviewInstant("2026-06-01T12:30:00Z"))
  #expect(reviewed.expected == String(decoding: expected, as: UTF8.self))
  #expect(try fixture.git(["rev-parse", receipt.auditRef!]) == receipt.commit)
  var after = try fixture.humanState()
  after.removeValue(forKey: "main")
  #expect(after == checkout)
  #expect(throws: (any Error).self) {
    try manager.confirmReviewed(base: catalog.base, entry: entry)
  }
  let updated = try manager.execute(
    MemoryManagementRequest(
      operation: .update, base: next.base, path: reviewed.path, locator: reviewed.locator,
      expected: reviewed.expected, replacement: fact("Requested correction."),
      reason: "Requested correction"), date: date.addingTimeInterval(100))
  let revised = try manager.reviewCatalog(cwd: fixture.repo).entries[0]
  #expect(revised.reviewed == reviewed.reviewed)
  _ = try manager.confirmReviewed(
    base: updated.commit!, entry: revised, date: date.addingTimeInterval(200))
  let final = try manager.reviewCatalog(cwd: fixture.repo).entries[0]
  #expect(final.identity == reviewed.identity && final.revised == revised.revised)
  #expect(
    final.expected
      == revised.expected.replacingOccurrences(of: reviewed.reviewed!, with: final.reviewed!))
}

@Test func approvedReviewCannotRepairMalformedOrDuplicateIdentity() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let bytes = try MemoryDocument.reviewedBytes(
    Data(fact("Duplicate.").utf8), identity: UUID(),
    instant: MemoryDocument.ReviewInstant("2026-01-01T00:00:00Z"))
  let malformed = "Malformed. [source: owner; added: 2024-02-29] [memory-id: bad; reviewed: bad]\n"
  try fixture.write(
    "# Memory\n\n" + String(decoding: bytes, as: UTF8.self) + "\n"
      + String(decoding: bytes, as: UTF8.self) + "\n" + malformed, path: "MEMORY.md")
  try fixture.commit()
  let manager = try MemoryManagement(repository: fixture.repo)
  let catalog = try manager.reviewCatalog(cwd: fixture.repo)
  #expect(catalog.entries.count == 3 && catalog.entries.allSatisfy { !$0.isMutable })
  let before = try fixture.humanState()
  for entry in catalog.entries {
    #expect(throws: (any Error).self) {
      try manager.confirmReviewed(base: catalog.base, entry: entry)
    }
  }
  #expect(try fixture.humanState() == before)
}
