import Foundation

package struct MemoryIntegrityReport: Encodable {
  package struct Check: Encodable {
    let component: String
    let status: String
    let reason: String?
  }

  let approvedBase: String
  let checks: [Check]
  package var isValid: Bool { checks.allSatisfy { $0.status == "valid" } }

  package static func inspect(configuration: MemoryConfiguration) throws -> Self {
    let store = try MemoryStore(repo: configuration.memoryURL)
    let base = try store.approvedCommit()
    var checks: [Check] = []
    func check(_ component: String, _ operation: () throws -> Void) {
      do {
        try operation()
        checks.append(Check(component: component, status: "valid", reason: nil))
      } catch {
        checks.append(
          Check(
            component: component, status: (error as? DreamRunError) == .busy ? "busy" : "blocked",
            reason: MemoryFailureDiagnostic.code(error)))
      }
    }
    check("approved-documents") {
      guard try store.check().isEmpty else { throw DreamRunError.corruption }
    }
    check("dream-completed-chain") {
      let sources = try configuration.reviewSources(
        stateRoot: configuration.stateURL, memoryRepository: configuration.memoryURL,
        isReadOnly: true)
      _ = try sources.verifiedCompletedReviewCandidates()
    }
    check("dream-saved-runs") {
      let inspection = try DreamInspection.read(stateRoot: configuration.stateURL)
      guard !inspection.isBusy else { throw DreamRunError.busy }
      guard inspection.runs.allSatisfy({ $0.diagnostic == nil }) else {
        throw DreamRunError.corruption
      }
    }
    check("committed-queue-binding") {
      _ = try MemoryQueue.committedSnapshot(
        configuration: configuration,
        request: MemoryQueueRequest(sessionID: "integrity", requestID: "integrity"))
    }
    check("approved-base-unchanged") {
      guard try store.approvedCommit() == base else { throw DreamRunError.staleGeneration }
    }
    return Self(approvedBase: base, checks: checks)
  }
}
