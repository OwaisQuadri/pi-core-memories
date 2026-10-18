import Foundation
import Testing

@testable import CoreMemories

@Test func reviewSourcesRejectsAnotherRepositoryEvenWhenItsApprovedBaseMatches() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate()
  _ = try fixture.store().run(
    selection: fixture.selection,
    prepare: { try fixture.prepare($0) }, call: { try transactionAdd($0) })
  let other = fixture.root.appendingPathComponent("other-memory")
  try FileManager.default.copyItem(at: fixture.memory, to: other)
  #expect(try MemoryStore(repo: other, environment: [:]).approvedCommit() == fixture.main())
  let configuration = MemoryConfiguration.defaults
  _ = try configuration.reviewSources(stateRoot: fixture.state, memoryRepository: fixture.memory)
  let before = try fixture.snapshot(fixture.state)
  let first = try fixture.main()
  let second = try MemoryStore(repo: other, environment: [:]).approvedCommit()
  #expect(throws: (any Error).self) {
    try configuration.reviewSources(stateRoot: fixture.state, memoryRepository: other)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
  #expect(try fixture.main() == first)
  #expect(try MemoryStore(repo: other, environment: [:]).approvedCommit() == second)
}
