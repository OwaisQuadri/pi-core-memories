import AppKit
import Testing

@testable import CoreMemoriesApp

@Test @MainActor func nativeUndoUsesTextOnlyForAnEditableResponder() {
  let editor = NSTextView()
  editor.isEditable = true
  #expect(editableUndoResponder(editor) === editor)
  editor.isEditable = false
  editor.isSelectable = true
  #expect(editableUndoResponder(editor) == nil)
  #expect(editableUndoResponder(NSResponder()) == nil)
  #expect(editableUndoResponder(nil) == nil)
}
