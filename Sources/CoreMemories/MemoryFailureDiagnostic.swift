import Foundation

package enum MemoryFailureDiagnostic {
  package static func code(_ error: any Error) -> String {
    if let dream = error as? DreamRunError {
      switch dream {
      case .busy: return "writer-busy"
      case .corruption: return "invalid-saved-state"
      case .unsafeState: return "unsafe-storage-identity"
      case .missingPayload: return "missing-saved-payload"
      case .unsupportedSchema: return "unsupported-schema"
      case .staleGeneration: return "stale-generation"
      default: return "dream-validation-failed"
      }
    }
    switch (error as? MemoryError)?.description {
    case "queue binding conflict", "repository queue binding conflict":
      return "queue-binding-conflict"
    case "repository review profile differs from its native queue binding":
      return "review-profile-conflict"
    case "queue-bound publication requires its verified native review profile":
      return "publication-profile-conflict"
    case "equivalent memory is already approved":
      return "already-approved"
    case "finding is stale, blocked, or suppressed", "candidate is not selectable":
      return "finding-not-selectable"
    case "release the active review first":
      return "active-review"
    case "frozen target document changed", "selected memory changed or is ambiguous",
      "selected native entry changed or is ambiguous":
      return "target-changed"
    default: return "validation-failed"
    }
  }
}
