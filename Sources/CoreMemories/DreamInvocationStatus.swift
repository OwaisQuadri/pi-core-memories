import Darwin
import Foundation

package struct DreamInvocationStatus: Sendable {
  package let status: String
  package let reason: String?
  package let detail: String?
  package let runID: String?
  package let observedAt: Date

  package init?(report: [String: Any], observedAt: Date = Date()) {
    guard let status = report["status"] as? String,
      ["completed", "pending", "noNewRecords", "busy", "blocked"].contains(status)
    else { return nil }
    self.status = status
    reason = report["reason"] as? String
    detail = report["detail"] as? String
    runID = report["runID"] as? String
    self.observedAt = observedAt
  }

  package var isPublicationBlocked: Bool {
    status == "pending" && reason == "staleUnpublishedPlans"
  }

  package var title: String {
    if isPublicationBlocked { return "Publication blocked" }
    switch status {
    case "completed": return "Completed"
    case "noNewRecords": return "No new records"
    case "busy": return "Busy"
    case "blocked": return "Blocked"
    default: return "Pending"
    }
  }

  package var explanation: String {
    if isPublicationBlocked {
      return
        "Inference was saved, but publication is blocked because approved memory changed. No queue progress advanced for this saved batch, and no new review candidates were admitted from it. Saved replies are retained. Retry and Replace do not repair this state."
    }
    let meaning: String
    switch reason {
    case "cancelled": meaning = "The invocation was cancelled. Saved work is retained."
    case "interruptedCall", "callInterrupted":
      meaning = "The model call was interrupted before a reply was saved."
    case "callbackFailure": meaning = "The model call failed before its reply was saved."
    case "invalidDecision":
      meaning = "The saved reply failed validation. Queue progress did not advance."
    case "workerFailure": meaning = "The worker stopped before finishing."
    case "protocolFailure": meaning = "The worker and Pi disagreed on the protocol."
    default:
      meaning =
        status == "pending" ? "Saved work is pending; no terminal reason is established." : ""
    }
    return [meaning, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  package static func read(
    configuration: MemoryConfiguration, inspection: DreamInspection?
  ) throws -> Self? {
    guard FileManager.default.fileExists(atPath: configuration.diagnostics) else { return nil }
    let root = try DreamStateDirectory.openRoot(
      URL(fileURLWithPath: configuration.diagnostics), isCreating: false)
    let names = try root.names()
    guard names.count <= 256 else { throw DreamRunError.limitExceeded }
    let settings = try DreamRunEncoding.encode(configuration.settings)
    let roots = try configuration.roots.map { try DreamRunEncoding.encode($0) } ?? Data("null".utf8)
    var latest: (DreamStateDirectory, Date)?
    for name in names where UUID(uuidString: name) != nil {
      let invocation = try root.child(name)
      let requestBytes = try invocation.read("request.json", maximum: 262_144)
      guard let saved = try JSONSerialization.jsonObject(with: requestBytes) as? [String: Any],
        let requested = saved["requestedSettings"],
        let request = saved["request"] as? [String: Any],
        let savedRoots = request["roots"],
        try canonicalJSON(requested) == canonicalJSON(JSONSerialization.jsonObject(with: settings)),
        try canonicalJSON(savedRoots)
          == canonicalJSON(JSONSerialization.jsonObject(with: roots, options: .fragmentsAllowed)),
        (request["deviceKey"] as? String) == configuration.deviceKey,
        (request["projectBindings"] as? [String: String] ?? [:]) == configuration.projectBindings
      else { continue }
      let date = try invocation.modificationDate("request.json")
      if latest == nil || date > latest!.1 { latest = (invocation, date) }
    }
    guard let (invocation, _) = latest else { return nil }
    let events = try invocation.names().compactMap { name -> (String, Int)? in
      guard name.hasPrefix("event-"), name.hasSuffix(".json"),
        let number = Int(name.dropFirst(6).dropLast(5)), (1...10_000).contains(number)
      else { return nil }
      return (name, number)
    }
    guard let last = events.max(by: { $0.1 < $1.1 }) else { return nil }
    let bytes = try invocation.read(last.0, maximum: 1_048_576)
    guard let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      event["event"] as? String == "report", let report = event["report"] as? [String: Any],
      let status = Self(report: report, observedAt: try invocation.modificationDate(last.0))
    else { return nil }
    if let id = status.runID {
      guard let run = inspection?.runs.first(where: { $0.id == id }),
        run.isCompleted == (status.status == "completed")
      else { return nil }
    }
    return status
  }

  private static func canonicalJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
  }
}

extension DreamStateDirectory {
  fileprivate func modificationDate(_ name: String) throws -> Date {
    var status = stat()
    guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw DreamRunError.unsafeState
    }
    try DreamRunStore.validateStateIdentity(status, isDirectory: false)
    return Date(
      timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
        + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
  }
}
