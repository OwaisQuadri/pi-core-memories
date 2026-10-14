import Foundation

/// Validates memory paths and Markdown annotations without judging source truth.
/// Its operations accept Markdown bytes and repository-relative paths.
/// - Returns: Path verdicts or annotation failures through its operations.
/// - Throws: Nothing.
public enum MemoryDocument {
  /// Identifies paths that can contain approved memory.
  /// - Parameter path: A repository-relative file path.
  /// - Returns: Whether the path is MEMORY.md or a lowercase SHA-256 project file.
  /// - Throws: Nothing.
  public static func isAllowedPath(_ path: String) -> Bool {
    path == "MEMORY.md" || isMatch(#"\Aprojects/[0-9a-f]{64}\.md\z"#, path)
  }

  /// Checks annotations on Markdown paragraphs and list items.
  /// - Parameter data: UTF-8 Markdown bytes; headings and reference definitions need no annotation.
  /// - Returns: Syntax and date failures, or an empty array for valid input.
  /// - Throws: Nothing; invalid UTF-8 is returned as a failure.
  public static func failures(in data: Data) -> [String] {
    readableFailures(in: data) + reviewMetadataFailures(in: data)
  }

  static func readableFailures(in data: Data) -> [String] {
    guard let text = String(data: data, encoding: .utf8) else { return ["invalid UTF-8"] }
    guard !text.contains("\0") else { return ["NUL is not allowed in Markdown"] }
    guard let analysis = analyze(text) else { return ["cannot parse Markdown"] }
    let lines = analysis.lines
    let orderedBlocks = analysis.blocks
    return annotationFailures(lines: lines, blocks: orderedBlocks)
  }

  public struct ReviewInstant: Equatable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
      guard isMatch(#"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z"#, rawValue),
        isCalendarDate(String(rawValue.prefix(10))),
        let date = ISO8601DateFormatter().date(from: rawValue),
        ISO8601DateFormatter().string(from: date) == rawValue
      else { throw MemoryError("invalid explicit review instant") }
      self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(container.decode(String.self, forKey: .rawValue))
    }
  }

  public struct EntryLocator: Equatable, Sendable, Codable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) throws {
      guard start >= 0, start < end else { throw MemoryError("invalid native entry range") }
      self.start = start
      self.end = end
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        start: container.decode(Int.self, forKey: .start),
        end: container.decode(Int.self, forKey: .end))
    }
  }

  public struct MemoryEntry: Equatable, Sendable {
    public let locator: EntryLocator
    public let bytes: Data
    public let identity: UUID?
    public let lastReview: ReviewInstant?
    public let lastRevision: ReviewInstant?
    public let isMutable: Bool
    public let limitation: String?

    init(
      locator: EntryLocator, bytes: Data, identity: UUID?, lastReview: ReviewInstant?,
      lastRevision: ReviewInstant? = nil, isMutable: Bool, limitation: String?
    ) {
      self.locator = locator
      self.bytes = bytes
      self.identity = identity
      self.lastReview = lastReview
      self.lastRevision = lastRevision
      self.isMutable = isMutable
      self.limitation = limitation
    }
  }

  public static func entries(in data: Data) -> [MemoryEntry] {
    let blocks = nativeBlockRanges(in: data)
    let metadataRecords = blocks.map { reviewMetadata(in: data.subdata(in: $0.range)) }
    let counts = metadataRecords.compactMap(\.identity).reduce(into: [UUID: Int]()) {
      $0[$1, default: 0] += 1
    }
    return blocks.enumerated().map { index, block in
      let bytes = data.subdata(in: block.range)
      let metadata = metadataRecords[index]
      let failure =
        metadata.failure
        ?? (metadata.identity.map { counts[$0, default: 0] > 1 } == true
          ? "duplicate memory identity" : nil)
      return MemoryEntry(
        locator: try! EntryLocator(start: block.range.lowerBound, end: block.range.upperBound),
        bytes: bytes, identity: metadata.identity, lastReview: metadata.instant,
        lastRevision: metadata.revision,
        isMutable: block.isEligible && failure == nil && readableFailures(in: bytes).isEmpty,
        limitation: failure
          ?? (block.isEligible ? nil : "unsupported native entry container"))
    }
  }

  static func isMemoryContent(_ bytes: Data) -> Bool {
    guard let text = String(data: bytes, encoding: .utf8), let analysis = analyze(text) else {
      return false
    }
    return analysis.blocks.contains { $0.isAnnotationRequired }
  }

  static func reviewedBytes(_ bytes: Data, identity: UUID, instant: ReviewInstant) throws -> Data {
    guard var text = String(data: bytes, encoding: .utf8) else {
      throw MemoryError("invalid entry encoding")
    }
    let metadata = reviewMetadata(in: bytes)
    guard metadata.failure == nil, readableFailures(in: bytes).isEmpty,
      metadata.identity == nil || metadata.identity == identity,
      entries(in: bytes).filter(\.isMutable).count == 1
    else { throw MemoryError("entry review metadata or identity is not mutable") }
    let annotation =
      "[memory-id: \(identity.uuidString.lowercased()); reviewed: \(instant.rawValue)"
      + (metadata.revision.map { "; revised: \($0.rawValue)" } ?? "") + "]"
    if let range = metadata.range {
      text.replaceSubrange(range, with: annotation)
    } else {
      let suffix =
        text.hasSuffix("\r\n")
        ? "\r\n"
        : text.unicodeScalars.last.map { CharacterSet.newlines.contains($0) ? String($0) : "" }
          ?? ""
      if !suffix.isEmpty { text.removeLast(suffix.count) }
      text += " " + annotation + suffix
    }
    return Data(text.utf8)
  }

  static func revisedBytes(
    _ bytes: Data, previous: MemoryEntry?, identity: UUID, instant: ReviewInstant
  ) throws -> Data {
    guard var text = String(data: bytes, encoding: .utf8),
      reviewMetadata(in: bytes).identity == nil,
      entries(in: bytes).count == 1, entries(in: bytes).first?.isMutable == true
    else { throw MemoryError("replacement must be one annotated entry without identity metadata") }
    let suffix = text.hasSuffix("\r\n") ? "\r\n" : (text.hasSuffix("\n") ? "\n" : "")
    if !suffix.isEmpty { text.removeLast(suffix.count) }
    text +=
      " [memory-id: \(identity.uuidString.lowercased())"
      + (previous?.lastReview.map { "; reviewed: \($0.rawValue)" } ?? "")
      + "; revised: \(instant.rawValue)]" + suffix
    return Data(text.utf8)
  }

  static func sourceAnnotations(in bytes: Data) -> [String] {
    let text = String(decoding: bytes, as: UTF8.self)
    let regex = try! NSRegularExpression(
      pattern: #"\[source: ([^\[\];\r\n]+); added: ([0-9]{4}-[0-9]{2}-[0-9]{2})\]"#)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
      String(text[Range($0.range, in: text)!])
    }
  }

  private static func reviewMetadata(in bytes: Data) -> (
    identity: UUID?, instant: ReviewInstant?, revision: ReviewInstant?, failure: String?,
    range: Range<String.Index>?
  ) {
    let text = String(decoding: bytes, as: UTF8.self)
    let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: true)
    guard let parsed = try? AttributedString(markdown: text, options: options) else {
      return (nil, nil, nil, "cannot parse review metadata", nil)
    }
    var lineStarts = [0]
    let raw = Array(bytes)
    for index in raw.indices where raw[index] == 10 || raw[index] == 13 {
      if raw[index] == 13, index + 1 < raw.count, raw[index + 1] == 10 { continue }
      lineStarts.append(index + 1)
    }
    let allowed: [Range<Int>] = parsed.runs.compactMap { run -> Range<Int>? in
      guard run.inlinePresentationIntent?.contains(.code) != true,
        !(run.presentationIntent?.components.contains(where: {
          if case .codeBlock = $0.kind { return true }
          return false
        }) ?? false), let position = run.markdownSourcePosition,
        position.startLine <= lineStarts.count, position.endLine <= lineStarts.count
      else { return nil }
      let start = lineStarts[position.startLine - 1] + position.startColumn - 1
      let end = lineStarts[position.endLine - 1] + position.endColumn
      return start..<end
    }
    let regex = try! NSRegularExpression(
      pattern: #"(?i)\[\s*(memory-id|reviewed|revised)\b\s*:[^\]\r\n]*(?:\]|$)"#)
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter {
      guard let range = Range($0.range, in: text) else { return false }
      let start = text[..<range.lowerBound].utf8.count
      let end = start + text[range].utf8.count
      var slashCount = 0
      var cursor = start
      while cursor > 0, raw[cursor - 1] == 92 {
        slashCount += 1
        cursor -= 1
      }
      return slashCount.isMultiple(of: 2)
        && allowed.contains { $0.contains(start) && end <= $0.upperBound }
    }
    guard matches.count <= 1 else {
      return (nil, nil, nil, "malformed or duplicate explicit review metadata", nil)
    }
    guard let match = matches.first, let range = Range(match.range, in: text) else {
      return (nil, nil, nil, nil, nil)
    }
    let annotation = String(text[range])
    let exact = try! NSRegularExpression(
      pattern:
        #"\A\[memory-id: ([0-9A-Fa-f-]{36})(?:; reviewed: ([^;\]\r\n]+))?(?:; revised: ([^;\]\r\n]+))?\]\z"#
    )
    guard
      let record = exact.firstMatch(
        in: annotation, range: NSRange(annotation.startIndex..., in: annotation)),
      let identity = UUID(
        uuidString: String(annotation[Range(record.range(at: 1), in: annotation)!]))
    else { return (nil, nil, nil, "invalid memory identity or explicit review instant", nil) }
    let review = Range(record.range(at: 2), in: annotation).map { String(annotation[$0]) }
    let revision = Range(record.range(at: 3), in: annotation).map { String(annotation[$0]) }
    guard review != nil || revision != nil,
      review == nil || (try? ReviewInstant(review!)) != nil,
      revision == nil || (try? ReviewInstant(revision!)) != nil
    else { return (nil, nil, nil, "invalid memory review or revision instant", nil) }
    return (
      identity, review.flatMap { try? ReviewInstant($0) },
      revision.flatMap { try? ReviewInstant($0) }, nil, range
    )

  }

  private static func reviewMetadataFailures(in data: Data) -> [String] {
    var identities: Set<UUID> = []
    var failures: [String] = []
    for entry in entries(in: data) {
      if let failure = reviewMetadata(in: entry.bytes).failure { failures.append(failure) }
      if let identity = entry.identity, !identities.insert(identity).inserted {
        failures.append("duplicate memory identity")
      }
    }
    return failures
  }

  private static func analyze(_ text: String) -> (lines: [String], blocks: [Block])? {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
    let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: true)
    let references = referenceBlocks(lines, options: options)
    var validationLines = lines
    for reference in references {
      for index in (reference.firstLine - 1)..<reference.lastLine {
        validationLines[index] = ""
      }
    }
    guard
      let parsed = try? AttributedString(
        markdown: validationLines.joined(separator: "\n"), options: options)
    else {
      return nil
    }
    var blocks: [Int: Block] = [:]
    for run in parsed.runs {
      guard let position = run.markdownSourcePosition else { continue }
      let firstLine = max(1, min(lines.count, position.startLine))
      let lastLine = max(firstLine, min(lines.count, position.endLine))
      let intent = run.presentationIntent?.components.first
      let identity = intent?.identity ?? -firstLine
      let isAnnotationRequired: Bool
      switch intent?.kind {
      case .header, .thematicBreak: isAnnotationRequired = false
      default: isAnnotationRequired = true
      }
      if var block = blocks[identity] {
        block.firstLine = min(block.firstLine, firstLine)
        block.lastLine = max(block.lastLine, lastLine)
        blocks[identity] = block
      } else {
        blocks[identity] = Block(
          firstLine: firstLine, lastLine: lastLine, isAnnotationRequired: isAnnotationRequired,
          isHeading: intent.map { if case .header = $0.kind { true } else { false } } ?? false,
          isAnchorSupported: intent?.kind == .paragraph,
          isRootParagraph: intent?.kind == .paragraph
            && run.presentationIntent?.components.count == 1)
      }
    }
    var covered = Set<Int>()
    var orderedBlocks = (Array(blocks.values) + references).sorted { $0.firstLine < $1.firstLine }
    for index in orderedBlocks.indices {
      let nextLine = orderedBlocks[index].lastLine + 1
      if orderedBlocks[index].isHeading, nextLine <= lines.count,
        isMatch(#"^\s*(>\s*)*(=+|-+)\s*$"#, lines[nextLine - 1])
      {
        orderedBlocks[index].lastLine = nextLine
      }
      covered.formUnion(orderedBlocks[index].firstLine...orderedBlocks[index].lastLine)
    }
    var index = 1
    while index <= lines.count {
      if covered.contains(index) || isMatch(#"^\s*(>\s*)*$"#, lines[index - 1]) {
        index += 1
        continue
      }
      let isExempt = isThematicBreak(lines[index - 1], options: options)
      orderedBlocks.append(
        Block(
          firstLine: index, lastLine: index, isAnnotationRequired: !isExempt,
          isAnchorSupported: false))
      index += 1
    }
    return (lines, orderedBlocks.sorted { $0.firstLine < $1.firstLine })
  }

  private static func annotationFailures(lines: [String], blocks orderedBlocks: [Block]) -> [String]
  {
    var failures: [String] = []
    let pattern = #"\[source: ([^\[\];\r\n]+); added: ([0-9]{4}-[0-9]{2}-[0-9]{2})\]"#
    let regex = try! NSRegularExpression(pattern: pattern)
    for record in orderedBlocks {
      let firstLine = record.firstLine
      let block = lines[(record.firstLine - 1)..<record.lastLine].joined(separator: "\n")
      let annotations = regex.matches(in: block, range: NSRange(block.startIndex..., in: block))
      if annotations.isEmpty && record.isAnnotationRequired {
        failures.append(
          "line \(firstLine): missing or malformed [source: reference; added: YYYY-MM-DD]")
      }
      var remainder = block
      for annotation in annotations.reversed() {
        let sourceRange = Range(annotation.range(at: 1), in: block)!
        let dateRange = Range(annotation.range(at: 2), in: block)!
        let source = String(block[sourceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty
          || source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        {
          failures.append(
            "line \(firstLine): source reference must be nonempty and contain no controls")
        }
        if !isCalendarDate(String(block[dateRange])) {
          failures.append("line \(firstLine): added date is not a real calendar date")
        }
        remainder.removeSubrange(Range(annotation.range, in: remainder)!)
      }
      if isMatch(#"(?i)\[\s*(source|added)\b\s*:"#, remainder) {
        failures.append("line \(firstLine): malformed metadata")
      }
    }
    return failures
  }

  struct NativeBlockRange: Equatable, Sendable {
    let range: Range<Int>
    let isEligible: Bool
    let isRootParagraph: Bool
  }

  static func nativeBlockRanges(in data: Data) -> [NativeBlockRange] {
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
      let analysis = analyze(text)
    else { return [] }
    var starts = [0]
    var ends: [Int] = []
    var offset = 0
    let scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      offset += scalar.utf8.count
      if CharacterSet.newlines.contains(scalar) {
        if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
          index += 1
          offset += 1
        }
        ends.append(offset)
        starts.append(offset)
      }
      index += 1
    }
    ends.append(offset)
    guard starts.count == analysis.lines.count else { return [] }
    let ranges = analysis.blocks.map { block in
      starts[block.firstLine - 1]..<ends[block.lastLine - 1]
    }
    let overlaps = overlapFlags(in: ranges)
    return analysis.blocks.enumerated().map { index, block in
      let range = ranges[index]
      let isOverlapping = overlaps[index]
      return NativeBlockRange(
        range: range,
        isEligible: block.isAnnotationRequired && block.isAnchorSupported && !range.isEmpty
          && !isOverlapping,
        isRootParagraph: block.isRootParagraph && !isOverlapping)
    }
  }

  static func overlapFlags(in ranges: [Range<Int>]) -> [Bool] {
    var flags = Array(repeating: false, count: ranges.count)
    var nextStart = Int.max
    for index in ranges.indices.reversed() {
      let range = ranges[index]
      guard !range.isEmpty else { continue }
      flags[index] = nextStart < range.upperBound
      nextStart = range.lowerBound
    }
    var maximumEnd = Int.min
    for index in ranges.indices {
      let range = ranges[index]
      guard !range.isEmpty else { continue }
      flags[index] = flags[index] || maximumEnd > range.lowerBound
      maximumEnd = max(maximumEnd, range.upperBound)
    }
    return flags
  }

  private struct Block {
    var firstLine: Int
    var lastLine: Int
    let isAnnotationRequired: Bool
    var isHeading = false
    var isAnchorSupported = true
    var isRootParagraph = false
  }

  private static func isThematicBreak(
    _ raw: String, options: AttributedString.MarkdownParsingOptions
  ) -> Bool {
    guard let parsed = try? AttributedString(markdown: raw, options: options) else { return false }
    return !parsed.runs.isEmpty
      && parsed.runs.allSatisfy { $0.presentationIntent?.components.first?.kind == .thematicBreak }
  }

  private static func referenceBlocks(
    _ lines: [String], options: AttributedString.MarkdownParsingOptions
  ) -> [Block] {
    let labelPattern = #"^\s*(>\s*)*\[((?:\\.|[^\[\]\\])+)\]:"#
    let regex = try! NSRegularExpression(pattern: labelPattern)
    var references: [Block] = []
    let text = lines.joined(separator: "\n")
    var label = "core-memory-definition-probe"
    while text.contains(label) { label += "-unique" }
    var candidateLines = lines
    var candidates: [String: Int] = [:]
    var probes = ""
    for (index, line) in lines.enumerated() {
      guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let labelRange = Range(match.range(at: 2), in: line)
      else { continue }
      let marker = "\(label)-\(index)"
      candidateLines[index].replaceSubrange(labelRange, with: marker)
      candidates[marker] = index
      probes += "[\(marker)][\(marker)]\n\n"
    }
    guard !candidates.isEmpty,
      let parsed = try? AttributedString(
        markdown: probes + candidateLines.joined(separator: "\n"), options: options)
    else { return [] }
    let active = Set(
      parsed.runs.compactMap { run in candidates[String(parsed[run.range].characters)] })
    for index in active.sorted() {
      var end = index + 1
      while end < lines.count, !isMatch(#"^\s*(>\s*)*$"#, lines[end]),
        !isMatch(labelPattern, lines[end])
      {
        end += 1
      }
      while end > index {
        if isReferenceDefinition(lines[index..<end].joined(separator: "\n"), options: options) {
          references.append(Block(firstLine: index + 1, lastLine: end, isAnnotationRequired: false))
          break
        }
        end -= 1
      }
    }
    return references
  }

  private static func isReferenceDefinition(
    _ raw: String, options: AttributedString.MarkdownParsingOptions
  ) -> Bool {
    guard let prefixRange = raw.range(of: #"^\s*(>\s*)*"#, options: .regularExpression),
      isMatch(#"^\s*(>\s*)*\[(?:\\.|[^\[\]\\])+\]:"#, raw)
    else { return false }
    let prefix = String(raw[prefixRange])
    let marker = "core-memory-reference-probe"
    guard
      let expected = try? AttributedString(markdown: prefix + marker, options: options),
      let parsed = try? AttributedString(
        markdown: raw + "\n" + prefix + "\n" + prefix + marker, options: options)
    else { return false }
    return String(parsed.characters) == marker
      && parsed.runs.count == expected.runs.count
      && parsed.runs.first?.presentationIntent == expected.runs.first?.presentationIntent
  }

  static func isCalendarDate(_ text: String) -> Bool {
    let components = text.split(separator: "-").compactMap { Int($0) }
    guard components.count == 3 else { return false }
    let (year, month, day) = (components[0], components[1], components[2])
    guard year > 0, (1...12).contains(month) else { return false }
    let isLeapYear =
      year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let days = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return (1...days[month - 1]).contains(day)
  }

  static func isMatch(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }
}
