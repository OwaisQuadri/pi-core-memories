import Testing

@testable import CoreMemories

@Test(arguments: [
  ("Please save that memory as shown.", "add", "approve"),
  ("Yes, please store this memory!", "update", "approve"),
  ("Remember the displayed memory", "add", "approve"),
  ("Keep the memory shown without changes", "update", "approve"),
  ("I approve the displayed memory change.", "delete", "approve"),
  ("Yes, please forget that memory.", "delete", "approve"),
  ("Remove this memory", "delete", "approve"),
  ("Mark this memory as reviewed", "confirm-reviewed", "approve"),
  ("Reject that memory suggestion.", "add", "reject"),
  ("Don't remember this memory", "update", "reject"),
  ("Do not delete that memory", "delete", "reject"),
  ("Leave that memory suggestion for later.", "add", "defer"),
  ("Skip this memory for now", "update", "defer"),
  ("Cancel that memory change", "delete", "defer"),
])
func memoryReplyRequiresAnExplicitActionForTheNativeOperation(
  text: String, operation: String, expected: String
) {
  #expect(
    interpretMemoryConversationReply(
      originalText: text, submittedText: text, operation: operation, isDetachRequired: false
    ).rawValue == expected)
}

@Test(arguments: [
  "Yes", "Okay", "Looks good", "Save it", "Remember Toronto", "",
  "Yes, but change Toronto to Ottawa.", "Save that memory if the source is right.",
  "Save that memory and delete another one.", "'Save that memory'", "\"Save that memory\"",
  "Would 'save that memory' work?", "I previously said save that memory.",
])
func memoryReplyDoesNotTurnDiscussionOrAcknowledgementIntoAChange(text: String) {
  for operation in ["add", "update", "delete", "confirm-reviewed"] {
    #expect(
      interpretMemoryConversationReply(
        originalText: text, submittedText: text, operation: operation, isDetachRequired: false
      ) == .clarify)
  }
}

@Test func memoryReplyCannotSubstituteSubmittedIntentOrTheWrongNativeOperation() {
  for (original, submitted, operation) in [
    ("Yes", "Save that memory", "add"),
    ("Save that memory", "Do not save that memory", "add"),
    ("Forget that memory", "Forget that memory", "update"),
    ("Save that memory", "Save that memory", "delete"),
    ("Save that memory", "Save that memory", "confirm-reviewed"),
    ("Save that memory", "Save that memory", "unknown"),
  ] {
    #expect(
      interpretMemoryConversationReply(
        originalText: original, submittedText: submitted,
        operation: operation, isDetachRequired: false
      ) == .clarify)
  }
  #expect(
    interpretMemoryConversationReply(
      originalText: "  YES, please save that memory.\n", submittedText: "Save that memory",
      operation: "add", isDetachRequired: false
    ) == .approve)
}

@Test func memoryReplyDoesNotCombineCheckoutPreparationAndSaving() {
  #expect(
    interpretMemoryConversationReply(
      originalText: "Save that memory", submittedText: "Save that memory",
      operation: "add", isDetachRequired: true
    ) == .clarify)
  #expect(
    interpretMemoryConversationReply(
      originalText: "Detach the memory checkout", submittedText: "Detach the memory checkout",
      operation: "add", isDetachRequired: true
    ) == .detach)
  for (text, isDetachRequired) in [
    ("Detach the memory checkout", false),
    ("Detach the memory checkout and save that memory", true),
  ] {
    #expect(
      interpretMemoryConversationReply(
        originalText: text, submittedText: text,
        operation: "add", isDetachRequired: isDetachRequired
      ) == .clarify)
  }
}
