import Foundation
import Testing

@testable import CoreMemories

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
