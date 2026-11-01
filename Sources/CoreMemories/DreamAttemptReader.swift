import Foundation

struct DreamResponseAttempt {
  static let maximumReplacements = 32
  let number: Int
  var responseName: String {
    number == 0 ? "response.json" : "replacement-\(number)-response.json"
  }
  var callName: String {
    number == 0 ? "call-started.json" : "replacement-\(number)-call-started.json"
  }
  var intentName: String { "replacement-\(number).json" }
  var archiveName: String { "rejected-\(number).json" }
}

struct VerifiedDreamAttempt {
  let attempt: DreamResponseAttempt
  let replacement: DreamRunEncoding.ReplacementIntent?
  let replacementHash: SourceDigest?
  let callIntentHash: SourceDigest?
  let selection: DreamSelectedCall?
  let response: DurableDreamResponse?
  let rendering: DreamRequestRendering
}

struct DreamAttemptReader {
  let directory: DreamStateDirectory
  let run: FrozenDreamRun
  let context: DreamDecisionContext
  let baseline: DreamModelRequest
  let rendering: DreamRequestRendering
  let admissionHash: SourceDigest
  let limits: DreamRunLimits

  var maximumResponseEnvelopeBytes: Int {
    limits.maximumResponseBytes * 6 + DreamRunEncoding.maximumMetadataBytes
  }

  func request(
    attempt: DreamResponseAttempt, replacement: DreamRunEncoding.ReplacementIntent?,
    replacementHash: SourceDigest?, selection: DreamSelectedCall
  ) throws -> DreamModelRequest {
    var messages = baseline.messages
    var systemPrompt = baseline.systemPrompt
    var hash = baseline.requestHash
    if let replacement, replacement.schemaVersion == 3 || replacement.schemaVersion == 4 {
      guard let replacementHash else { throw DreamRunError.corruption }
      if replacement.schemaVersion == 3 {
        guard let feedback = replacement.feedback else { throw DreamRunError.corruption }
        messages.append(
          DreamRequestMessage(
            role: .user, text: String(decoding: try feedback.bytes(), as: UTF8.self),
            timestampMilliseconds: messages[0].timestampMilliseconds))
      } else {
        guard rendering == .priorContextV5,
          replacement.targetRenderingVersion == DreamRequestRendering.scopeContractV6.rawValue
        else { throw DreamRunError.corruption }
        systemPrompt = context.systemPrompt(rendering: .scopeContractV6)
        messages = try context.requestMessages(
          timestampMilliseconds: messages[0].timestampMilliseconds, rendering: .scopeContractV6)
      }
      let bytes = try DreamRunEncoding.encode(
        DreamRunEncoding.EffectiveCall(
          runID: run.runID, generation: run.progress.generation,
          inputHash: run.inputHash.rawValue, contextHash: context.contextHash.rawValue,
          admissionHash: admissionHash.rawValue, baselineRequestHash: baseline.requestHash.rawValue,
          replacementIntentHash: replacementHash.rawValue, attemptNumber: attempt.number,
          selection: DreamRunEncoding.Selection(selection), systemPrompt: systemPrompt,
          messages: messages))
      guard bytes.count <= limits.maximumFrozenBytes else { throw DreamRunError.limitExceeded }
      hash = SourceDigest(bytes: bytes)
    }
    return DreamModelRequest(
      runID: baseline.runID, generation: baseline.generation,
      inputHash: baseline.inputHash, contextHash: baseline.contextHash, requestHash: hash,
      selection: selection, systemPrompt: systemPrompt, messages: messages)
  }

  func verify(visit: (VerifiedDreamAttempt) throws -> Void = { _ in }) throws
    -> VerifiedDreamAttempt
  {
    let replacementNames = try directory.names().filter { $0.hasPrefix("replacement-") }
    let names = replacementNames.filter {
      !$0.hasSuffix("-response.json") && !$0.hasSuffix("-call-started.json")
    }
    guard names.count <= DreamResponseAttempt.maximumReplacements else {
      throw DreamRunError.limitExceeded
    }
    let expected = Set(
      (1..<(names.count + 1)).flatMap {
        let attempt = DreamResponseAttempt(number: $0)
        return [attempt.intentName, attempt.callName, attempt.responseName]
      })
    guard replacementNames.allSatisfy(expected.contains) else { throw DreamRunError.corruption }
    var previous = try load(attempt: DreamResponseAttempt(number: 0))
    try visit(previous)
    for number in 1..<(names.count + 1) {
      let attempt = DreamResponseAttempt(number: number)
      guard names.contains(attempt.intentName), let rejectedResponse = previous.response else {
        throw DreamRunError.corruption
      }
      let bytes = try directory.read(
        attempt.intentName, maximum: DreamRunEncoding.maximumMetadataBytes)
      let intent = try DreamRunEncoding.decode(
        DreamRunEncoding.ReplacementIntent.self, bytes: bytes)
      let rejected = try directory.read(attempt.archiveName, maximum: maximumResponseEnvelopeBytes)
      guard bytes == (try DreamRunEncoding.encode(intent)),
        intent.admissionHash == admissionHash.rawValue,
        intent.requestHash == baseline.requestHash.rawValue,
        intent.rejectedResponseHash == SourceDigest(bytes: rejected).rawValue,
        rejected
          == (try directory.read(
            previous.attempt.responseName, maximum: maximumResponseEnvelopeBytes))
      else { throw DreamRunError.corruption }
      guard
        case .failure(let rejection) = DreamDecision.assess(
          response: rejectedResponse, context: context, rendering: previous.rendering)
      else { throw DreamRunError.corruption }
      switch intent.schemaVersion {
      case 2:
        guard intent.attemptNumber == nil, intent.rejectedAttemptNumber == nil,
          intent.rejectedCallIntentHash == nil, intent.feedback == nil, intent.feedbackHash == nil,
          intent.targetRenderingVersion == nil
        else { throw DreamRunError.corruption }
      case 3, 4:
        let feedback = DreamReplacementFeedback(
          failure: rejection.failure, rendering: previous.rendering)
        guard intent.attemptNumber == number, intent.rejectedAttemptNumber == number - 1,
          intent.rejectedCallIntentHash == previous.callIntentHash?.rawValue,
          intent.feedback == feedback,
          intent.feedbackHash == SourceDigest(bytes: try feedback.bytes()).rawValue,
          intent.targetRenderingVersion
            == (intent.schemaVersion == 4 ? DreamRequestRendering.scopeContractV6.rawValue : nil),
          intent.schemaVersion != 4 || rendering == .priorContextV5
        else { throw DreamRunError.corruption }
      default: throw DreamRunError.unsupportedSchema
      }
      previous = try load(
        attempt: attempt, replacement: intent, replacementHash: SourceDigest(bytes: bytes))
      try visit(previous)
    }
    return previous
  }

  private func load(
    attempt: DreamResponseAttempt, replacement: DreamRunEncoding.ReplacementIntent? = nil,
    replacementHash: SourceDigest? = nil
  ) throws -> VerifiedDreamAttempt {
    let effectiveRendering: DreamRequestRendering =
      replacement?.schemaVersion == 4 ? .scopeContractV6 : rendering
    guard try directory.isPresent(attempt.callName) else {
      guard !(try directory.isPresent(attempt.responseName)) else { throw DreamRunError.corruption }
      return VerifiedDreamAttempt(
        attempt: attempt, replacement: replacement,
        replacementHash: replacementHash, callIntentHash: nil, selection: nil, response: nil,
        rendering: effectiveRendering)
    }
    let callBytes = try directory.read(
      attempt.callName, maximum: DreamRunEncoding.maximumMetadataBytes)
    let call = try DreamRunEncoding.decode(DreamRunEncoding.Intent.self, bytes: callBytes)
    let isEffective = replacement?.schemaVersion == 3 || replacement?.schemaVersion == 4
    let selection: DreamSelectedCall
    do { selection = try call.selection?.domain() ?? run.selection } catch {
      throw DreamRunError.corruption
    }
    let request = try request(
      attempt: attempt, replacement: replacement,
      replacementHash: replacementHash, selection: selection)
    guard callBytes == (try DreamRunEncoding.encode(call)),
      call.admissionHash == admissionHash.rawValue, call.requestHash == request.requestHash.rawValue
    else { throw DreamRunError.corruption }
    if isEffective {
      guard call.schemaVersion == 3, call.selection != nil,
        call.baselineRequestHash == baseline.requestHash.rawValue,
        call.replacementIntentHash == replacementHash?.rawValue,
        call.attemptNumber == attempt.number
      else { throw DreamRunError.corruption }
    } else {
      guard call.schemaVersion == 2, call.baselineRequestHash == nil,
        call.replacementIntentHash == nil, call.attemptNumber == nil
      else { throw DreamRunError.corruption }
    }
    let callHash = SourceDigest(bytes: callBytes)
    var response: DurableDreamResponse?
    if try directory.isPresent(attempt.responseName) {
      let bytes = try directory.read(attempt.responseName, maximum: maximumResponseEnvelopeBytes)
      let bound = try DreamRunEncoding.decode(DreamRunEncoding.BoundResponse.self, bytes: bytes)
      guard bound.schemaVersion == (isEffective ? 3 : 2),
        bound.callIntentHash == (isEffective ? callHash.rawValue : nil)
      else { throw DreamRunError.corruption }
      response = try bound.domain(
        run: run, context: context, request: request,
        admissionHash: admissionHash, selection: selection, bytes: bytes,
        maximumResponseBytes: limits.maximumResponseBytes)
    }
    return VerifiedDreamAttempt(
      attempt: attempt, replacement: replacement,
      replacementHash: replacementHash, callIntentHash: callHash, selection: selection,
      response: response, rendering: effectiveRendering)
  }
}
