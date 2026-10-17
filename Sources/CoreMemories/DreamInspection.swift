import Darwin
import Foundation

package struct DreamArtifact: Codable, Sendable, Identifiable {
  package let runID: String
  package let name: String
  package let byteCount: Int
  package let digest: String
  package var id: String { runID + "/" + name }
}

package struct SavedDreamRun: Codable, Sendable, Identifiable {
  package let id: String
  package let isCompleted: Bool
  package let artifacts: [DreamArtifact]
}

package struct DreamInspection: Codable, Sendable {
  package let isPresent: Bool
  package let isBusy: Bool
  package let runs: [SavedDreamRun]

  package static func read(stateRoot: URL) throws -> Self {
    var status = stat()
    if lstat(stateRoot.path, &status) != 0 {
      guard errno == ENOENT else { throw DreamRunError.unsafeState }
      return Self(isPresent: false, isBusy: false, runs: [])
    }
    let root = try DreamStateDirectory.openRoot(stateRoot, isCreating: false)
    guard try root.isPresent("writer.lock") else {
      if try root.names().isEmpty { return Self(isPresent: true, isBusy: false, runs: []) }
      throw DreamRunError.missingPayload
    }
    let lock = try root.openReadLock()
    defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
    guard flock(lock, LOCK_SH | LOCK_NB) == 0 else {
      return Self(isPresent: true, isBusy: true, runs: [])
    }
    try root.verifyLock(lock)
    _ = try root.retainedBytes(maximum: 1_073_741_824)
    let bytes = try root.read("root.json", maximum: 1_048_576)
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      object["schemaVersion"] as? Int == 2
    else { throw DreamRunError.unsupportedSchema }
    let directory = try root.child("runs")
    let runs = try directory.names().map { id -> SavedDreamRun in
      guard DreamRunEncoding.isRunID(id) else { throw DreamRunError.corruption }
      let run = try directory.child(id)
      var artifacts: [DreamArtifact] = []
      for name in try run.names() {
        if name == "receipts" {
          let receipts = try run.child(name)
          for receipt in try receipts.names() {
            try appendArtifact(receipts, name: receipt, relative: "receipts/" + receipt, runID: id, to: &artifacts)
          }
        } else if !name.hasPrefix(".") {
          try appendArtifact(run, name: name, relative: name, runID: id, to: &artifacts)
        }
      }
      return SavedDreamRun(id: id, isCompleted: artifacts.contains { $0.name == "completion.json" }, artifacts: artifacts)
    }
    return Self(isPresent: true, isBusy: false, runs: runs)
  }

  package static func artifactBytes(_ artifact: DreamArtifact, stateRoot: URL) throws -> Data {
    guard DreamRunEncoding.isRunID(artifact.runID), isArtifactName(artifact.name) else {
      throw DreamRunError.unsafeState
    }
    let root = try DreamStateDirectory.openRoot(stateRoot, isCreating: false)
    var directory = try root.child("runs").child(artifact.runID)
    let components = artifact.name.split(separator: "/").map(String.init)
    if components.count == 2 { directory = try directory.child("receipts") }
    let bytes = try directory.read(components.last!, maximum: 33_554_432)
    guard bytes.count == artifact.byteCount, SourceDigest(bytes: bytes).rawValue == artifact.digest else {
      throw MemoryError("saved artifact changed; refresh inspection")
    }
    return bytes
  }

  package static func revealURL(_ artifact: DreamArtifact, stateRoot: URL) throws -> URL {
    _ = try artifactBytes(artifact, stateRoot: stateRoot)
    return try canonicalExistingFile(
      stateRoot.appendingPathComponent("runs").appendingPathComponent(artifact.runID)
        .appendingPathComponent(artifact.name))
  }

  private static func appendArtifact(
    _ directory: DreamStateDirectory, name: String, relative: String, runID: String,
    to artifacts: inout [DreamArtifact]
  ) throws {
    guard isArtifactName(relative) else { throw DreamRunError.corruption }
    let bytes = try directory.read(name, maximum: 33_554_432)
    _ = try JSONSerialization.jsonObject(with: bytes)
    artifacts.append(DreamArtifact(
      runID: runID, name: relative, byteCount: bytes.count,
      digest: SourceDigest(bytes: bytes).rawValue))
  }

  private static func isArtifactName(_ name: String) -> Bool {
    let components = name.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 1 || (components.count == 2 && components[0] == "receipts"),
      let last = components.last, last.hasSuffix(".json"), last.utf8.count <= 128
    else { return false }
    return last.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
  }
}

package func canonicalExistingFile(_ url: URL) throws -> URL {
  guard url.isFileURL, let resolved = realpath(url.path, nil) else { throw DreamRunError.unsafeState }
  defer { free(resolved) }
  guard url.path == String(cString: resolved) else { throw DreamRunError.unsafeState }
  var status = stat()
  guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
    throw MemoryError("file is missing or is not a canonical regular file")
  }
  return url
}
