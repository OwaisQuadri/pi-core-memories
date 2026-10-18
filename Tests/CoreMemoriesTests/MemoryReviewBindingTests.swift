import Darwin
import Foundation
import Testing

@testable import CoreMemories

@Test func reviewValidLegacyBindingMigrationPreservesDecisionsAndRequiresFreshPreview() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  try fixture.populate(texts: ["Keep A.", "Keep B.", "Keep C.", "Keep D."])
  let sources = try fixture.store()
  _ = try transactionCompleted(
    sources.run(
      selection: fixture.selection, prepare: { try fixture.prepare($0) },
      call: { try transactionAdd($0) }))
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  let rows = try controller!.list()
  try controller!.confirmDetach(controller!.checkoutPreview())
  let date = Date(timeIntervalSince1970: 1_783_036_799)
  _ = try controller!.apply(controller!.preview(candidateID: rows[0].change.id, clockDate: date))
  try controller!.reject(candidateID: rows[1].change.id)
  try controller!.deferCandidate(candidateID: rows[2].change.id)
  let stale = try controller!.preview(candidateID: rows[3].change.id, clockDate: date)
  controller = nil
  let memory = try fixture.snapshot(fixture.memory)
  let original = try fixture.snapshot(state)
  let rootURL = state.appendingPathComponent("root.json")
  let binding = try MemoryReviewEncoding.decode(
    ReviewRootBinding.self, bytes: Data(contentsOf: rootURL))
  var repositoryStatus = stat()
  var stateStatus = stat()
  var sourceStatus = stat()
  #expect(lstat(fixture.memory.path, &repositoryStatus) == 0)
  #expect(lstat(state.path, &stateStatus) == 0)
  #expect(lstat(fixture.state.path, &sourceStatus) == 0)
  let sourceHash = SourceDigest(
    bytes: try Data(contentsOf: fixture.state.appendingPathComponent("root.json")))
  let legacySource = SourceDigest(
    bytes: Data(
      "\(fixture.state.path)\0\(sourceStatus.st_dev)\0\(sourceStatus.st_ino)\0\(sourceHash.rawValue)"
        .utf8))
  #expect(try sources.reviewSourceBinding(isLegacy: true) == legacySource)
  let legacy = LegacyReviewRootBinding(
    schemaVersion: 1, repository: fixture.memory.path,
    repositoryDevice: UInt64(repositoryStatus.st_dev),
    repositoryInode: UInt64(repositoryStatus.st_ino),
    sourceBinding: legacySource.rawValue,
    stateDevice: UInt64(stateStatus.st_dev), stateInode: UInt64(stateStatus.st_ino))
  try MemoryReviewEncoding.encode(legacy).write(to: rootURL)
  for _ in 0..<2 {
    controller = try MemoryReviewController(
      repository: fixture.memory, stateRoot: state, sources: fixture.store(), environment: [:])
    #expect(
      try controller!.list().map(\.disposition) == [.approved, .rejected, .deferred, .pending])
    #expect(throws: (any Error).self) { try controller!.apply(stale) }
    #expect(try Data(contentsOf: rootURL) == MemoryReviewEncoding.encode(binding))
    controller = nil
    #expect(try fixture.snapshot(fixture.memory) == memory)
    #expect(
      try fixture.snapshot(state).filter { $0.key != rootURL.path }
        == original.filter { $0.key != rootURL.path })
  }
}

@Test func reviewPersistentBindingUsesVolumeUUIDsInsteadOfMountNumbers() throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  let controller = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  _ = try controller.list()
  let object =
    try JSONSerialization.jsonObject(
      with: Data(contentsOf: state.appendingPathComponent("root.json"))) as! [String: Any]
  #expect(object["schemaVersion"] as? Int == 2)
  #expect(object["repositoryDevice"] == nil)
  #expect(object["stateDevice"] == nil)
  let repositoryVolume = try fixture.memory.resourceValues(forKeys: [.volumeUUIDStringKey])
    .volumeUUIDString
  let stateVolume = try state.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
  #expect(object["repositoryVolumeUUID"] as? String == repositoryVolume)
  #expect(object["stateVolumeUUID"] as? String == stateVolume)
  #expect(object["state"] as? String == state.path)
  var status = stat()
  #expect(lstat(fixture.state.path, &status) == 0)
  let volume = try #require(
    fixture.state.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
  let hash = SourceDigest(
    bytes: try Data(contentsOf: fixture.state.appendingPathComponent("root.json")))
  let expected = SourceDigest(
    bytes: Data("\(fixture.state.path)\0\(volume)\0\(status.st_ino)\0\(hash.rawValue)".utf8))
  #expect(object["sourceBinding"] as? String == expected.rawValue)
  #expect(try sources.reviewSourceBinding() == expected)
}

@Test(arguments: [
  "repository", "repositoryVolumeUUID", "repositoryInode", "state", "stateVolumeUUID", "stateInode",
  "sourcePath", "sourceVolume", "sourceInode", "sourceRootBytes", "legacyMount",
  "legacySourceDigest",
  "legacyNoncanonical",
])
func reviewAlteredPersistentIdentityRefusesReopenWithoutWrites(field: String) throws {
  let fixture = try TransactionFixture()
  defer { fixture.clean() }
  let sources = try reviewCompletedSiblings(fixture)
  let state = fixture.root.appendingPathComponent("review")
  var controller: MemoryReviewController? = try MemoryReviewController(
    repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  _ = try controller!.list()
  controller = nil
  let rootURL = state.appendingPathComponent("root.json")
  var object = try JSONSerialization.jsonObject(with: Data(contentsOf: rootURL)) as! [String: Any]
  switch field {
  case "sourceRootBytes":
    let sourceURL = fixture.state.appendingPathComponent("root.json")
    var bytes = try Data(contentsOf: sourceURL)
    bytes.append(10)
    try bytes.write(to: sourceURL)
  case "legacyMount", "legacySourceDigest", "legacyNoncanonical":
    var repoStatus = stat()
    var stateStatus = stat()
    var sourceStatus = stat()
    #expect(lstat(fixture.memory.path, &repoStatus) == 0)
    #expect(lstat(state.path, &stateStatus) == 0)
    #expect(lstat(fixture.state.path, &sourceStatus) == 0)
    let hash = SourceDigest(
      bytes: try Data(contentsOf: fixture.state.appendingPathComponent("root.json")))
    let offset: UInt64 = field == "legacyMount" ? 1 : 0
    let sourceDevice = UInt64(sourceStatus.st_dev) + offset
    let sourceBinding =
      field == "legacySourceDigest"
      ? try sources.reviewSourceBinding().rawValue
      : SourceDigest(
        bytes: Data(
          "\(fixture.state.path)\0\(sourceDevice)\0\(sourceStatus.st_ino)\0\(hash.rawValue)".utf8)
      ).rawValue
    let legacy = LegacyReviewRootBinding(
      schemaVersion: 1, repository: fixture.memory.path,
      repositoryDevice: UInt64(repoStatus.st_dev) + offset,
      repositoryInode: UInt64(repoStatus.st_ino),
      sourceBinding: sourceBinding,
      stateDevice: UInt64(stateStatus.st_dev) + offset, stateInode: UInt64(stateStatus.st_ino))
    var bytes = try MemoryReviewEncoding.encode(legacy)
    if field == "legacyNoncanonical" { bytes.append(10) }
    try bytes.write(to: rootURL)
  case "sourcePath", "sourceVolume", "sourceInode":
    var status = stat()
    #expect(lstat(fixture.state.path, &status) == 0)
    let volume = try #require(
      fixture.state.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    let hash = SourceDigest(
      bytes: try Data(contentsOf: fixture.state.appendingPathComponent("root.json")))
    let path = field == "sourcePath" ? fixture.state.path + "-other" : fixture.state.path
    let identity = field == "sourceVolume" ? UUID().uuidString : volume
    let inode = UInt64(status.st_ino) + (field == "sourceInode" ? 1 : 0)
    object["sourceBinding"] =
      SourceDigest(
        bytes: Data("\(path)\0\(identity)\0\(inode)\0\(hash.rawValue)".utf8)
      ).rawValue
    try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
    )
    .write(to: rootURL)
  default:
    if field.hasSuffix("Inode") {
      object[field] = (object[field] as! UInt64) + 1
    } else {
      object[field] = (object[field] as! String) + "-other"
    }
    try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
    )
    .write(to: rootURL)
  }
  let before = try fixture.snapshot(fixture.root)
  #expect(throws: (any Error).self) {
    try MemoryReviewController(
      repository: fixture.memory, stateRoot: state, sources: sources, environment: [:])
  }
  #expect(try fixture.snapshot(fixture.root) == before)
}
