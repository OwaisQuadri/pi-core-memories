import Foundation
import Testing

@testable import CoreMemories

private func retargetedAliasStore(_ fixture: TransactionFixture, alias: URL, kind: String) throws
  -> DreamRunStore
{
  try DreamRunStore(
    stateRoot: fixture.state, sessionsRoot: kind == "sessions" ? alias : fixture.sessions,
    memoryRepository: kind == "memory" ? alias : fixture.memory,
    strippingRoots: [kind == "stripping" ? alias : fixture.snippets])
}

@Test(arguments: ["sessions", "stripping", "memory"])
func dreamTransportRetargetedAliasCannotAdmitForeignRoots(kind: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let alias = fixture.root.appendingPathComponent("configured-alias")
  let target =
    kind == "sessions" ? fixture.sessions : kind == "memory" ? fixture.memory : fixture.snippets
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
  let first = try retargetedAliasStore(fixture, alias: alias, kind: kind)
  _ = try first.run(
    selection: fixture.selection,
    prepare: {
      let roots = first.acceptedSources
      return try SessionReader(
        sessions: roots.sessions, snippets: roots.stripping.first, environment: [:]
      ).prepare(progress: $0, limits: DreamInputLimits())
    }, call: transactionUncalled)
  let foreign = fixture.root.appendingPathComponent("foreign")
  try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
  try FileManager.default.removeItem(at: alias)
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
  let second = try retargetedAliasStore(fixture, alias: alias, kind: kind)
  let before = try fixture.snapshot(fixture.state)
  #expect(throws: DreamRunError.unsafeState) {
    try second.run(
      selection: fixture.selection, prepare: transactionUncalledPrepare, call: transactionUncalled)
  }
  #expect(try fixture.snapshot(fixture.state) == before)
}
