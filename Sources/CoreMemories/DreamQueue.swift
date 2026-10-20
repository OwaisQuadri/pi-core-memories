import CoreFoundation
import Foundation

package struct DreamQueueCoverage: Sendable {
  package let backlogBytes: UInt64?
  package let backlogLimitBytes: UInt64?
  package let undreamtBytes: UInt64?
  package let nextBytes: UInt64?
  package let plannedBytes: UInt64
  package let completedBytes: UInt64

  package init(
    backlogBytes: UInt64?, backlogLimitBytes: UInt64?, undreamtBytes: UInt64?,
    nextBytes: UInt64?, plannedBytes: UInt64, completedBytes: UInt64
  ) throws {
    let maximum: UInt64 = 9_007_199_254_740_991
    guard
      [backlogBytes, backlogLimitBytes, undreamtBytes, nextBytes, plannedBytes, completedBytes]
        .compactMap({ $0 }).allSatisfy({ $0 <= maximum }),
      completedBytes <= plannedBytes,
      (backlogBytes == nil) == (undreamtBytes == nil),
      (backlogBytes == nil) == (backlogLimitBytes == nil),
      (undreamtBytes == nil) == (nextBytes == nil)
    else { throw MemoryError("invalid dream coverage") }
    if let backlogBytes, let undreamtBytes, let nextBytes {
      guard undreamtBytes <= backlogBytes, plannedBytes <= undreamtBytes,
        nextBytes <= undreamtBytes - plannedBytes
      else { throw MemoryError("invalid dream coverage counts") }
    }
    self.backlogBytes = backlogBytes
    self.backlogLimitBytes = backlogLimitBytes
    self.undreamtBytes = undreamtBytes
    self.nextBytes = nextBytes
    self.plannedBytes = plannedBytes
    self.completedBytes = completedBytes
  }

  package init(json: [String: Any]) throws {
    func count(_ key: String) throws -> UInt64? {
      if json[key] is NSNull { return nil }
      guard let number = json[key] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue >= 0,
        number.doubleValue <= 9_007_199_254_740_991,
        number.doubleValue.rounded(.towardZero) == number.doubleValue
      else { throw MemoryError("invalid dream coverage field: \(key)") }
      return number.uint64Value
    }
    guard let planned = try count("plannedBytes"), let completed = try count("completedBytes"),
      let repeated = try count("repeatedRecords"), repeated <= 1_000
    else { throw MemoryError("invalid dream batch coverage") }
    if !(json["estimateSeconds"] is NSNull) {
      guard let estimate = json["estimateSeconds"] as? NSNumber,
        CFGetTypeID(estimate) != CFBooleanGetTypeID(),
        estimate.doubleValue.isFinite, estimate.doubleValue > 0
      else { throw MemoryError("invalid dream estimate") }
    }
    try self.init(
      backlogBytes: count("backlogBytes"), backlogLimitBytes: count("backlogLimitBytes"),
      undreamtBytes: count("undreamtBytes"), nextBytes: count("nextBytes"),
      plannedBytes: planned, completedBytes: completed)
  }

  package var segments: (dreamt: UInt64, undreamt: UInt64, free: UInt64, total: UInt64)? {
    guard let backlogBytes, let backlogLimitBytes, let undreamtBytes else { return nil }
    let left = undreamtBytes - completedBytes
    let dreamt = backlogBytes - left
    return (
      dreamt, left, backlogLimitBytes > left ? backlogLimitBytes - left : 0,
      max(backlogLimitBytes, left) + dreamt
    )
  }
}

package struct DreamQueueSnapshot: Sendable {
  package let coverage: DreamQueueCoverage?
  package let observedAt: Date
  package let unavailableReason: String?

  package static func read(configuration: MemoryConfiguration, date: Date = Date()) -> Self {
    do {
      let sources = try configuration.reviewSources(
        stateRoot: configuration.stateURL, memoryRepository: configuration.memoryURL,
        isReadOnly: true)
      let historical = try sources.historicalSourceIdentities
      let roles = try configuration.queueSourceRoles(
        sessions: historical.sessions, stripping: historical.stripping)
      return Self(
        coverage: try sources.inspectQueue(
          isSnippetsPresent: roles.isSnippetsPresent, isPromptsPresent: roles.isPromptsPresent,
          date: date),
        observedAt: date, unavailableReason: nil)
    } catch DreamRunError.busy {
      return Self(
        coverage: nil, observedAt: date, unavailableReason: "Queue busy. Another dream is running.")
    } catch {
      return Self(coverage: nil, observedAt: date, unavailableReason: "Queue unavailable: \(error)")
    }
  }
}

extension MemoryConfiguration {
  package func queueSourceRoles(sessions: URL, stripping: [URL]) throws -> DreamSourceRoles {
    if let roots {
      return DreamSourceRoles(
        isSnippetsPresent: roots.snippets != nil, isPromptsPresent: roots.prompts != nil)
    }
    let agent = URL(fileURLWithPath: settings.agentDirectory)
    guard sessions.path == agent.appendingPathComponent("sessions").path else {
      throw MemoryError(
        "Saved queue belongs to another agent directory. Select its matching profile.")
    }
    let snippets = agent.appendingPathComponent("extensions/prompt-snippets/snippets")
    let prompts = agent.appendingPathComponent("prompts")
    let isSnippetsPresent = stripping.contains {
      $0.path == snippets.path
        || DreamRunStore.isManagedSnippets($0.path, state: stateURL, sessions: sessions)
    }
    let isPromptsPresent = stripping.contains { $0.path == prompts.path }
    let expected = (isSnippetsPresent ? [stripping[0]] : []) + (isPromptsPresent ? [prompts] : [])
    guard stripping.map(\.path) == expected.map(\.path) else {
      throw MemoryError("Named queue sources are unavailable for this profile")
    }
    return DreamSourceRoles(
      isSnippetsPresent: isSnippetsPresent, isPromptsPresent: isPromptsPresent)
  }
}
