import CoreMemories
import SwiftUI

struct MemoriesView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    HSplitView {
      VStack {
        HStack {
          Toggle("All devices", isOn: $model.isShowingAllDevices).toggleStyle(.switch).controlSize(
            .small)
          Spacer()
          Menu {
            Button("Global Memory") { model.add() }
            Button("This Device") {
              if let device = model.configuration.deviceKey {
                model.add(path: "devices/\(device)/MEMORY.md")
              }
            }.disabled(model.configuration.deviceKey == nil)
            Button("Project…") { Task { await model.addProject(isDeviceSpecific: false) } }
            Button("Project on This Device…") {
              Task { await model.addProject(isDeviceSpecific: true) }
            }
            .disabled(model.configuration.deviceKey == nil)
          } label: {
            Image(systemName: "plus")
          }.help("New Memory")
        }.padding(12)
        List {
          ForEach(Array(model.visibleEntries.enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: 6) {
              Button {
                model.edit(entry)
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(entry.expected).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                  Text(
                    MemoryScopeConfiguration.label(
                      path: entry.path, deviceKey: model.configuration.deviceKey)
                  )
                  .font(.caption).foregroundStyle(.secondary)
                  if !entry.isMutable {
                    Text(entry.limitation ?? "Read only").font(.caption).foregroundStyle(.orange)
                  }
                }.padding(.vertical, 5)
              }.buttonStyle(.plain)
              if entry.isMutable {
                Button("Confirm Reviewed") { Task { await model.confirmReviewed(entry) } }.font(
                  .caption)
              }
            }
          }
        }
      }.frame(minWidth: 260, idealWidth: 310)
      VStack(alignment: .leading, spacing: 14) {
        if model.isEditing {
          TextField(
            "Memory path",
            text: Binding(
              get: { model.editorPath },
              set: {
                model.editorPath = $0
                model.editorChanged()
              })
          )
          .disabled(model.isExistingEntry).font(.system(.body, design: .monospaced))
          Text(
            MemoryScopeConfiguration.label(
              path: model.editorPath, deviceKey: model.configuration.deviceKey)
          ).font(.headline)
          TextEditor(
            text: Binding(
              get: { model.editorText },
              set: {
                model.editorText = $0
                model.editorChanged()
              })
          )
          .font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.2))
          TextField(
            "Change reason",
            text: Binding(
              get: { model.editorReason },
              set: {
                model.editorReason = $0
                model.editorChanged()
              }))
          HStack {
            Button("Reveal Checkout in Finder") { Task { await model.revealMemory() } }
            Spacer()
            if model.isExistingEntry {
              Button("Delete Entry", role: .destructive) { model.deleteEntry() }.disabled(
                model.editorReason.isEmpty)
            }
          }
        } else {
          Text("Select a memory or create one").foregroundStyle(.secondary).frame(
            maxWidth: .infinity, maxHeight: .infinity)
        }
      }.padding(20).frame(minWidth: 400)
    }
  }
}

struct ChangesView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("\(model.operations.count) Draft Changes").font(.title2.bold())
        Spacer()
        Button("Discard Draft…", role: .destructive) { model.isConfirmingDiscard = true }.disabled(
          model.draft == nil)
        Button("Save One Commit") { Task { await model.save() } }.disabled(
          model.operations.isEmpty || model.isBusy)
      }
      if let draft = model.draft {
        Text("Base · \(draft.baseCommit)").font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      }
      List {
        ForEach(Array(model.operations.enumerated()), id: \.offset) { index, operation in
          DisclosureGroup {
            LabeledContent("Reason", value: operation.reason ?? "")
            if let expected = operation.expected {
              PlainTextView(text: expected).frame(height: 100)
            }
            if let replacement = operation.replacement {
              PlainTextView(text: replacement).frame(height: 130)
            }
            HStack {
              Button("Edit") { model.editOperation(index) }
              Button("Remove", role: .destructive) { model.removeOperation(index) }
            }
          } label: {
            Text("\(operation.operation.rawValue.capitalized) · \(operation.path ?? "")")
          }
        }
      }
      if !model.drafts.isEmpty {
        DisclosureGroup("Recover Draft") {
          ForEach(model.drafts, id: \.draftID) { draft in
            Button("\(draft.draftID.uuidString) · revision \(draft.revision)") {
              Task { await model.restore(draft) }
            }
          }
        }
      }
    }.padding(20)
      .alert("Discard Draft?", isPresented: $model.isConfirmingDiscard) {
        Button("Cancel", role: .cancel) {}
        Button("Discard", role: .destructive) { Task { await model.discard() } }
      } message: {
        Text("Approved memory will not change.")
      }
  }
}

struct ReviewView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    HSplitView {
      List {
        ForEach(model.candidates, id: \.change.id) { candidate in
          VStack(alignment: .leading, spacing: 8) {
            Text(String(decoding: candidate.change.after, as: UTF8.self)).lineLimit(4)
            Text(
              "\(candidate.disposition.rawValue.capitalized) · \(MemoryScopeConfiguration.label(path: candidate.change.path, deviceKey: model.configuration.deviceKey))"
            )
            .font(.caption).foregroundStyle(.secondary)
            if let limitation = candidate.limitation {
              Text(limitation).font(.caption).foregroundStyle(.orange)
            }
            HStack {
              Button("Preview") { Task { await model.showPreview(candidate) } }
              Button("Defer") { Task { await model.disposition(candidate, isRejected: false) } }
              Button("Reject", role: .destructive) {
                Task { await model.disposition(candidate, isRejected: true) }
              }
            }.disabled(![.pending, .deferred].contains(candidate.disposition))
          }.padding(.vertical, 8)
        }
      }.frame(minWidth: 300, idealWidth: 360)
      VStack(alignment: .leading, spacing: 12) {
        if let preview = model.preview {
          HStack {
            Text("Current Preview").font(.title2.bold())
            Spacer()
            Button("Back") { model.preview = nil }.keyboardShortcut(.cancelAction)
            Button("Approve This Entry") { Task { await model.approve() } }
          }
          Text("Base · \(preview.currentBase)").font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
          Text("Stored sources are references, not verified evidence.").font(.caption)
            .foregroundStyle(.secondary)
          PlainTextView(
            text: "BEFORE\n" + String(decoding: preview.before, as: UTF8.self)
              + "\n\nAFTER\n" + String(decoding: preview.after, as: UTF8.self)
              + "\n\nREASON\n" + preview.change.reason
              + "\n\nSOURCES\n"
              + preview.change.sources.map { $0.exactText }.joined(separator: "\n\n")
              + "\n\nCONTRADICTIONS\n" + String(describing: preview.change.contradictions))
        } else {
          Text("Select a candidate for a fresh preview").foregroundStyle(.secondary).frame(
            maxWidth: .infinity, maxHeight: .infinity)
        }
      }.padding(20).frame(minWidth: 400)
    }.task { await model.loadCandidates() }
  }
}
