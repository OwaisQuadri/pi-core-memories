import Foundation

enum DreamNoChangeReason: String, CaseIterable, Codable, Sendable {
  case notDurable, alreadyRepresented, insufficientEvidence, unresolvedScope

  static func allowed(for resolution: PinnedScopeResolution) -> [Self] {
    if case .unresolved = resolution { return [.unresolvedScope] }
    return allCases.filter { $0 != .unresolvedScope }
  }

  var meaning: String {
    switch self {
    case .notDurable: "The primary evidence does not express durable information."
    case .alreadyRepresented:
      "The supported durable information is already represented in supplied memory."
    case .insufficientEvidence:
      "There is insufficient primary support for a durable proposal in any frozen authorized destination. A missing destination does not mechanically select this reason; reassess the evidence and explain the absence of support."
    case .unresolvedScope:
      "Only sources whose frozen resolution is literally unresolved may use this reason. Resolved outsideGit and project sources forbid it."
    }
  }
}

enum DreamValidationCode: String, Codable, Sendable {
  case invalidSyntax, responseBinding, limitExceeded, schemaVersion, contextHash
  case expectedObject, objectFields, expectedString, expectedInteger, expectedArray
  case scopeShape, projectKey, deviceKey, unsupportedScope, absentScope, unknownSource
  case ineligibleSource, unresolvedEvidenceRequiresUnresolvedScope
  case resolvedEvidenceDisallowsUnresolvedScope, decisionShape, unsupportedDecision
  case sourceList, conflictingCoverage, ownerAnchorBytes, invalidDecisionShape
  case decisionCoverage, finalMarkdown
  case unsafeProse, referenceScope, memoryAnchor, ownerAnchor, ownerScope
  case contradictionShape, unsupportedContradiction, duplicateContradiction, updateAnchor,
    reasonCode

  var diagnostic: String {
    switch self {
    case .invalidSyntax: "Reply has invalid decision syntax"
    case .responseBinding: "response binding"
    case .limitExceeded: "Reply exceeds a frozen validation limit"
    case .schemaVersion: "schemaVersion must be 1"
    case .contextHash: "contextHash does not match the frozen request"
    case .expectedObject: "expected an object"
    case .objectFields: "object fields do not match the required fields"
    case .expectedString: "expected a string"
    case .expectedInteger: "expected an integer"
    case .expectedArray: "expected an array"
    case .scopeShape: "scope must be an object with a kind"
    case .projectKey: "project key must contain 64 lowercase hexadecimal characters"
    case .deviceKey: "device key is not the pinned device"
    case .unsupportedScope: "unsupported scope kind"
    case .absentScope: "scope is absent from the frozen memory snapshot"
    case .unknownSource: "source identity is absent from the pinned evidence"
    case .ineligibleSource: "source evidence is not eligible for the requested scope"
    case .unresolvedEvidenceRequiresUnresolvedScope:
      "unresolved evidence requires an unresolvedScope note"
    case .resolvedEvidenceDisallowsUnresolvedScope:
      "unresolvedScope cannot be used for resolved evidence"
    case .decisionShape: "decision must be an object with a kind"
    case .unsupportedDecision: "unsupported decision kind"
    case .sourceList: "sources must be nonempty and contain no duplicate identity"
    case .conflictingCoverage: "a source has conflicting terminal and proposal decisions"
    case .ownerAnchorBytes: "owner anchor bytes do not match pinned slice"
    case .invalidDecisionShape: "schema, identity, scope or coverage"
    case .decisionCoverage: "decision coverage"
    case .finalMarkdown: "final Markdown or unchanged file"
    case .unsafeProse:
      "Text must be nonempty single-line prose without controls or source/date annotations."
    case .referenceScope: "Contradiction scope does not match the target scope."
    case .memoryAnchor: "Memory anchor does not match one complete eligible frozen block."
    case .ownerAnchor:
      "Owner anchor identity, hash, range, or UTF-8 boundary does not match pinned input."
    case .ownerScope: "Owner scope does not match every primary source's project."
    case .contradictionShape: "Contradiction must be a supported object with a kind."
    case .unsupportedContradiction: "Contradiction kind is unsupported."
    case .duplicateContradiction: "Contradictions contain a duplicate identity."
    case .updateAnchor:
      "Update requires a matching non-overlapping eligible anchor and its memory contradiction."
    case .reasonCode: "noChange reasonCode must be one of the four supplied reasons."
    }
  }

  var field: String? {
    switch self {
    case .schemaVersion: "schemaVersion"
    case .contextHash: "contextHash"
    case .unresolvedEvidenceRequiresUnresolvedScope, .resolvedEvidenceDisallowsUnresolvedScope,
      .reasonCode:
      "reasonCode"
    case .scopeShape, .projectKey, .deviceKey, .unsupportedScope, .absentScope, .ineligibleSource:
      "scope"
    case .unknownSource, .sourceList: "sources"
    case .ownerAnchorBytes, .ownerAnchor, .ownerScope: "owner"
    case .memoryAnchor, .updateAnchor: "anchor"
    case .referenceScope, .contradictionShape, .unsupportedContradiction, .duplicateContradiction:
      "contradictions"
    default: nil
    }
  }
}

struct DreamValidationFailure: Codable, Equatable, Sendable {
  let code: DreamValidationCode
  var decisionIndex: Int?
  let diagnostic: String
  var fieldPath: [String]
  var resolutionCounts: [String: Int]
  var permittedNoChangeReasons: [DreamNoChangeReason]
  var expectedFields: [String]?
  var unexpectedFieldCount: Int?

  init(
    code: DreamValidationCode, decisionIndex: Int? = nil,
    resolutions: [PinnedScopeResolution] = []
  ) {
    self.code = code
    self.decisionIndex = decisionIndex
    diagnostic = code.diagnostic
    fieldPath = code.field.map { [$0] } ?? []
    if let decisionIndex { fieldPath = ["decisions", String(decisionIndex)] + fieldPath }
    var counts: [String: Int] = [:]
    var reasons = DreamNoChangeReason.allCases
    for resolution in resolutions {
      let kind: String =
        switch resolution {
        case .unresolved: "unresolved"
        case .outsideGit: "outsideGit"
        case .project: "project"
        }
      counts[kind, default: 0] += 1
      let allowed = DreamNoChangeReason.allowed(for: resolution)
      reasons.removeAll { !allowed.contains($0) }
    }
    resolutionCounts = counts
    permittedNoChangeReasons = resolutions.isEmpty ? [] : reasons
  }

  func atDecision(_ index: Int) -> Self {
    var failure = self
    failure.decisionIndex = index
    failure.fieldPath = ["decisions", String(index)] + fieldPath
    return failure
  }
}

struct DreamDecisionShapeFailure: Error {
  let code: DreamValidationCode
}

struct DreamDecisionRejection: Error {
  let error: DreamDecisionError
  let failure: DreamValidationFailure
}

struct DreamReplacementFeedback: Codable, Equatable {
  static let maximumBytes = 16_384
  let schemaVersion: Int
  let kind: String
  let renderingVersion: Int
  let failure: DreamValidationFailure
  let constraints: [String]

  init(failure: DreamValidationFailure, rendering: DreamRequestRendering) {
    schemaVersion = 1
    kind = "validationFeedbackNotEvidence"
    renderingVersion = rendering.rawValue
    self.failure = failure
    constraints = [
      "Reassess the original primary evidence under the frozen request contract.",
      "Use only frozen authorized destinations; do not infer project identity or globalize project-local facts.",
      "Do not mechanically substitute a reason. Feedback does not choose an outcome.",
      "Return a complete replacement decision object. Later decisions have not been certified valid.",
      "Use the supplied decision schema and exact frozen identities and anchors. For grouped noChange decisions every source must permit the reason; split groups with no shared reason.",
    ]
  }

  func bytes() throws -> Data {
    let bytes = try DreamRunEncoding.encode(self)
    guard bytes.count <= Self.maximumBytes else { throw DreamRunError.limitExceeded }
    return bytes
  }
}
