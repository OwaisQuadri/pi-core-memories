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
                  Text(
                    (try? MemoryDocument.editableEntry(Data(entry.expected.utf8))) ?? entry.expected
                  )
                  .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
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
        Text("Your Changes").font(.title2.bold())
        Spacer()
        Button("Discard Draft…", role: .destructive) { model.isConfirmingDiscard = true }.disabled(
          model.draft == nil)
        Button("Save Changes") { Task { await model.save() } }.disabled(
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
      VStack(spacing: 0) {
        Picker("Candidates", selection: $model.isShowingReviewedCandidates) {
          Text("To Review (\(model.actionableCandidates.count))").tag(false)
          Text("Reviewed (\(model.reviewedCandidates.count))").tag(true)
        }.pickerStyle(.segmented).padding(12)
        List {
          if model.isShowingReviewedCandidates {
            ForEach(model.reviewedCandidates, id: \.change.id) { candidate in
              candidateRow(candidate)
            }
            if model.reviewedCandidates.isEmpty { Text("No reviewed candidates") }
          } else {
            if model.isReviewLoading {
              ProgressView("Loading suggestions…")
            } else if model.actionableCandidates.isEmpty {
              Text(model.reviewEmptyMessage)
            }
            ForEach(model.actionableCandidates, id: \.change.id) { candidate in
              candidateRow(candidate)
            }
            if !model.blockedCandidates.isEmpty {
              Section("Blocked (\(model.blockedCandidates.count))") {
                ForEach(model.blockedCandidates, id: \.change.id) { candidate in
                  candidateRow(candidate)
                }
              }
            }
          }
        }
      }.frame(minWidth: 300, idealWidth: 390)
      VStack(alignment: .leading, spacing: 12) {
        if let preview = model.preview {
          HStack {
            Text("Review Suggestion").font(.title2.bold())
            Spacer()
            Button("Back") { model.preview = nil }.keyboardShortcut(.cancelAction)
            Button("Save into Memory") { Task { await model.approve() } }
          }
          Text(MemoryDocument.reviewText(preview.change.after)).font(.headline)
          PlainTextView(
            text: "BEFORE\n"
              + (preview.before.isEmpty ? "New memory" : MemoryDocument.reviewText(preview.before))
              + "\n\nAFTER\n" + MemoryDocument.reviewText(preview.after)
              + "\n\nREASON\n" + preview.change.reason)
          DisclosureGroup("Details") {
            Text("Base · \(preview.currentBase)").font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
            Text("Stored sources are references, not verified evidence.").font(.caption)
            PlainTextView(
              text: "STORED ENTRY\n" + String(decoding: preview.after, as: UTF8.self)
                + "\n\nSOURCES\n"
                + preview.change.sources.map { $0.exactText }.joined(separator: "\n\n")
                + "\n\nCONTRADICTIONS\n" + String(describing: preview.change.contradictions)
            )
            .frame(height: 180)
          }
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Text(model.reviewEmptyMessage)
              .foregroundStyle(.secondary)
            if model.invocationStatus?.isPublicationBlocked == true {
              Button("Prepare Saved Suggestions…") { model.section = "Dreams" }
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }.padding(20).frame(minWidth: 400)
    }.task { await model.loadCandidates() }
      .onChange(of: model.isShowingReviewedCandidates) { _ in model.preview = nil }
  }

  private func dispositionTitle(_ disposition: MemoryReviewDisposition) -> String {
    switch disposition {
    case .pending: "To review"
    case .deferred: "Decide later"
    case .approved: "Saved into memory"
    case .rejected: "Dismissed"
    case .blocked: "Blocked"
    }
  }

  private func candidateRow(_ candidate: MemoryReviewCandidate) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(MemoryDocument.reviewText(candidate.change.after)).lineLimit(4)
      Text(
        "\(dispositionTitle(candidate.disposition)) · \(MemoryScopeConfiguration.label(path: candidate.change.path, deviceKey: model.configuration.deviceKey))"
      )
      .font(.caption).foregroundStyle(.secondary)
      if let limitation = candidate.limitation {
        Text(limitation).font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Button("Review Suggestion") { Task { await model.showPreview(candidate) } }
        Button("Decide Later") { Task { await model.disposition(candidate, isRejected: false) } }
        Button("Dismiss", role: .destructive) {
          Task { await model.disposition(candidate, isRejected: true) }
        }
      }.disabled(![.pending, .deferred].contains(candidate.disposition))
    }.padding(.vertical, 8)
  }
}
