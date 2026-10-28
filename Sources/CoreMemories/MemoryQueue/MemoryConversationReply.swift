import Foundation

package enum MemoryConversationAction: String, Sendable {
  case approve, reject
  case postpone = "defer"
  case detach, clarify
}

private func memoryReplyText(_ text: String) -> String {
  var result = text.lowercased().replacingOccurrences(of: "’", with: "'")
    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  while result.last == "." || result.last == "!" { result.removeLast() }
  result = result.trimmingCharacters(in: .whitespacesAndNewlines)
  for prefix in ["yes, ", "yes ", "sure, ", "okay, "] where result.hasPrefix(prefix) {
    result.removeFirst(prefix.count)
    break
  }
  for prefix in ["please ", "i would like to ", "i want to ", "i want you to "]
  where result.hasPrefix(prefix) {
    result.removeFirst(prefix.count)
    break
  }
  for suffix in [" exactly as shown", " without changes", " as shown", " please"]
  where result.hasSuffix(suffix) {
    result.removeLast(suffix.count)
    break
  }
  return result
}

package func interpretMemoryConversationReply(
  originalText: String, submittedText: String, operation: String, isDetachRequired: Bool
) -> MemoryConversationAction {
  guard ["add", "update", "delete", "confirm-reviewed"].contains(operation) else {
    return .clarify
  }
  let text = memoryReplyText(originalText)
  guard !text.isEmpty, text == memoryReplyText(submittedText) else { return .clarify }
  let objects = ["this memory", "that memory", "the displayed memory", "the memory shown"]
  if objects.contains(where: { object in
    [
      "reject \(object)", "reject \(object) suggestion", "reject \(object) proposal",
      "reject \(object) change", "do not save \(object)", "don't save \(object)",
      "do not remember \(object)", "don't remember \(object)",
      "do not delete \(object)", "don't delete \(object)",
    ].contains(text)
  }) {
    return .reject
  }
  if objects.contains(where: { object in
    [
      "defer \(object)", "defer \(object) suggestion", "leave \(object) for later",
      "leave \(object) suggestion for later", "skip \(object) for now",
      "set \(object) aside", "cancel \(object) change",
    ].contains(text)
  }) {
    return .postpone
  }
  if ["detach the memory checkout", "detach this memory checkout", "prepare the memory checkout"]
    .contains(text)
  {
    return isDetachRequired ? .detach : .clarify
  }
  guard !isDetachRequired else { return .clarify }
  if objects.contains(where: { object in
    ["approve \(object) change", "i approve \(object) change"].contains(text)
  }) {
    return .approve
  }
  let verbs: [String]
  switch operation {
  case "add", "update": verbs = ["save", "store", "remember", "keep"]
  case "delete": verbs = ["forget", "remove", "delete"]
  default:
    return objects.contains(where: { object in
      ["mark \(object) reviewed", "mark \(object) as reviewed", "confirm \(object) as reviewed"]
        .contains(text)
    }) ? .approve : .clarify
  }
  return verbs.contains(where: { verb in
    objects.contains(where: { text == "\(verb) \($0)" })
  }) ? .approve : .clarify
}
