import Darwin
import Foundation

package struct DreamArtifact: Codable, Sendable, Identifiable {
  package let runID: String
  package let name: String
  package let byteCount: Int
  package let digest: String
  package var id: String { runID + "/" + name }
}

package struct SavedDreamAttempt: Codable, Sendable, Identifiable {
  package let number: Int
  package let provider: String
  package let modelID: String
  package let thinkingLevel: String
  package let status: String
  package let suggestionCount: Int?
  package let diagnostic: String?
  package var id: Int { number }
}

package struct SavedDreamRun: Codable, Sendable, Identifiable {
  package let id: String
  package let generation: UInt64?
  package let approvedBase: String?
  package let isCompleted: Bool
  package let attempts: [SavedDreamAttempt]
  package let diagnostic: String?
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
    defer {
      _ = flock(lock, LOCK_UN)
      _ = close(lock)
    }
    guard flock(lock, LOCK_SH | LOCK_NB) == 0 else {
      return Self(isPresent: true, isBusy: true, runs: [])
    }
    try root.verifyLock(lock)
    _ = try root.retainedBytes(maximum: 1_073_741_824, isDreamAuthority: true)
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
            try appendArtifact(
              receipts, name: receipt, relative: "receipts/" + receipt, runID: id, to: &artifacts)
          }
        } else if !name.hasPrefix(".") {
          try appendArtifact(run, name: name, relative: name, runID: id, to: &artifacts)
        }
      }
      do {
        return try inspectRun(
          root: root, directory: run, id: id,
          bindingHash: SourceDigest(bytes: bytes), artifacts: artifacts)
      } catch {
        return SavedDreamRun(
          id: id, generation: nil, approvedBase: nil,
          isCompleted: artifacts.contains { $0.name == "completion.json" }, attempts: [],
          diagnostic: String(describing: error), artifacts: artifacts)
      }
    }
    return Self(
      isPresent: true, isBusy: false,
      runs: runs.sorted {
        if $0.generation != $1.generation { return ($0.generation ?? 0) > ($1.generation ?? 0) }
        return $0.id < $1.id
      })
  }

  private static func inspectRun(
    root: DreamStateDirectory, directory: DreamStateDirectory, id: String,
    bindingHash: SourceDigest, artifacts: [DreamArtifact]
  ) throws -> SavedDreamRun {
    let limits = try DreamRunLimits()
    let input = try directory.read("input.json", maximum: limits.maximumFrozenBytes)
    let run = try DreamRunEncoding.frozen(
      bytes: input, runID: id,
      inputHash: SourceDigest(bytes: input), bindingHash: bindingHash, limits: limits)
    let context = try DreamRunEncoding.context(
      bytes: directory.read("context.json", maximum: limits.maximumFrozenBytes), run: run)
    let requestBytes = try directory.read("request.json", maximum: limits.maximumFrozenBytes)
    let verifiedRequest = try DreamRunEncoding.decode(
      DreamRunEncoding.Request.self, bytes: requestBytes
    ).verifiedDomain(run: run, context: context, bytes: requestBytes)
    let request = verifiedRequest.request
    let admissionBytes = try root.child("admissions").read(
      "\(run.progress.generation).json", maximum: DreamRunEncoding.maximumMetadataBytes)
    let admission = try DreamRunEncoding.decode(
      DreamRunEncoding.Admission.self, bytes: admissionBytes)
    guard admission.runID == id, admission.inputHash == run.inputHash.rawValue,
      admission.contextHash == context.contextHash.rawValue,
      admission.requestHash == request.requestHash.rawValue,
      admission.bindingHash == bindingHash.rawValue,
      admission.generation == run.progress.generation, admission.base == run.approvedBase,
      try admission.selection.domain() == run.selection
    else { throw DreamRunError.corruption }
    let reader = DreamAttemptReader(
      directory: directory, run: run, context: context, baseline: request,
      rendering: verifiedRequest.rendering,
      admissionHash: SourceDigest(bytes: admissionBytes), limits: limits)
    var attempts: [SavedDreamAttempt] = []
    _ = try reader.verify { attempt in
      guard let selection = attempt.selection else { return }
      var status = "No saved reply"
      var suggestionCount: Int?
      var diagnostic: String?
      if let response = attempt.response {
        switch DreamDecision.assess(
          response: response, context: context, rendering: verifiedRequest.rendering)
        {
        case .success(let result):
          suggestionCount = result.plans.count
          status = "Reply valid"
        case .failure(let rejection):
          status = "Rejected reply"
          switch rejection.error {
          case .decision(let index, let category):
            diagnostic = "Decision index \(index): \(category)"
          case .context(let message): diagnostic = message
          case .schema: diagnostic = "Reply has invalid decision syntax"
          case .limitExceeded: diagnostic = "Reply exceeds a frozen validation limit"
          }
        }
      }
      attempts.append(
        SavedDreamAttempt(
          number: attempt.attempt.number, provider: selection.provider,
          modelID: selection.modelID, thinkingLevel: selection.thinkingLevel,
          status: status, suggestionCount: suggestionCount, diagnostic: diagnostic))
    }
    return SavedDreamRun(
      id: id, generation: run.progress.generation, approvedBase: run.approvedBase,
      isCompleted: artifacts.contains { $0.name == "completion.json" }, attempts: attempts,
      diagnostic: nil, artifacts: artifacts)
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
    guard bytes.count == artifact.byteCount, SourceDigest(bytes: bytes).rawValue == artifact.digest
    else {
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
    artifacts.append(
      DreamArtifact(
        runID: runID, name: relative, byteCount: bytes.count,
        digest: SourceDigest(bytes: bytes).rawValue))
  }

  private static func isArtifactName(_ name: String) -> Bool {
    let components = name.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 1 || (components.count == 2 && components[0] == "receipts"),
      let last = components.last, last.hasSuffix(".json"), last.utf8.count <= 128
    else { return false }
    return last.utf8.allSatisfy {
      (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
    }
  }
}

package func canonicalExistingFile(_ url: URL) throws -> URL {
  guard url.isFileURL, let resolved = realpath(url.path, nil) else {
    throw DreamRunError.unsafeState
  }
  defer { free(resolved) }
  guard url.path == String(cString: resolved) else { throw DreamRunError.unsafeState }
  var status = stat()
  guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
    throw MemoryError("file is missing or is not a canonical regular file")
  }
  return url
}
