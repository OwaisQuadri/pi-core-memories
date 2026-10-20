import CoreMemories
import SwiftUI

struct MemoryWorkspaceView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Group {
      if model.isReviewLoading && model.batchProjection == nil {
        ProgressView("Loading memories…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !model.isLoaded {
        Text("Memories unavailable").font(.headline)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        workspace
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task { await model.loadCandidates() }
    .alert("Start Independent Manual Batch?", isPresented: $model.isConfirmingIndependentManual) {
      Button("Start Manual Batch") { Task { await model.startIndependentManualBatch() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Existing Save recovery remains pending.")
    }
    .alert("Discard Draft?", isPresented: $model.isConfirmingDiscard) {
      Button("Cancel", role: .cancel) {}
      Button("Discard", role: .destructive) { Task { await model.discard() } }
    } message: {
      Text("Approved memory will not change.")
    }
  }

  private var workspace: some View {
    VStack(spacing: 0) {
      HSplitView {
        VStack(spacing: 0) {
          HStack {
            Toggle("All devices", isOn: $model.isShowingAllDevices).toggleStyle(.switch)
              .controlSize(.small)
            Spacer()
            Menu {
              Button("Global Memory") { Task { await model.add() } }
              Button("This Device") {
                if let device = model.configuration.deviceKey {
                  Task { await model.add(path: "devices/\(device)/MEMORY.md") }
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
              .disabled(!model.draftRecoveries.isEmpty && model.batchProjection == nil)
          }.padding(12)
          List(
            selection: Binding(
              get: { model.selection },
              set: { value in
                Task { await model.selectMemory(value) }
              })
          ) {
            Section("Changes (\(model.stagedItems.count))") {
              ForEach(model.stagedItems, id: \.itemID) { item in
                VStack(alignment: .leading, spacing: 4) {
                  Text(item.title)
                  if let path = model.memoryPath(for: item) {
                    Text(model.scopeLabel(path: path)).font(.caption).foregroundStyle(.secondary)
                  }
                  Text(model.summary(for: item)).lineLimit(2).foregroundStyle(.secondary)
                  if model.batchProjection?.needsReview.contains(item.itemID) == true {
                    Text("Needs Review").foregroundStyle(.orange)
                  }
                }.tag(NativeMemorySelection.staged(item.itemID))
              }
            }
            Section("To Review") {
              ForEach(model.actionableCandidates, id: \.change.id) { candidate in
                candidateRow(candidate)
              }
            }
            Section("Saved Memories") {
              ForEach(model.visibleEntries, id: \.nativeID) { entry in
                VStack(alignment: .leading, spacing: 4) {
                  Text(MemoryDocument.reviewText(Data(entry.expected.utf8))).lineLimit(3)
                  Text(model.scopeLabel(path: entry.path)).font(.caption).foregroundStyle(
                    .secondary)
                }.tag(NativeMemorySelection.entry(entry.path, entry.locator.start))
                  .disabled(!model.draftRecoveries.isEmpty && model.batchProjection == nil)
              }
            }
            Section("Blocked") {
              ForEach(model.blockedCandidates, id: \.change.id) { candidate in
                candidateRow(candidate)
              }
            }
            if !model.draftRecoveries.isEmpty {
              Section("Recovery Required") {
                ForEach(model.draftRecoveries, id: \.failure.saveID) { recovery in
                  Text("Unverified Save").tag(
                    NativeMemorySelection.recovery(recovery.failure.saveID))
                }
                Button("Start Manual Batch…") { model.isConfirmingIndependentManual = true }
                  .disabled(!model.isIndependentManualEnabled)
              }
            }
            Section("Saved History") {
              ForEach(model.reviewedCandidates, id: \.change.id) { candidate in
                candidateRow(candidate)
              }
            }
          }
          if let page = model.batchProjection {
            HStack {
              Button("Previous") {
                Task { await model.loadPage(offset: max(0, page.catalogOffset - 64)) }
              }
              .disabled(page.catalogOffset == 0)
              Spacer()
              Text(
                max(page.entryCount, page.candidateCount) == 0
                  ? "0"
                  : "\(page.catalogOffset + 1)–\(min(page.catalogOffset + 64, max(page.entryCount, page.candidateCount)))"
              )
              .font(.caption)
              Spacer()
              Button("Next") { Task { await model.loadPage(offset: page.catalogOffset + 64) } }
                .disabled(page.catalogOffset + 64 >= max(page.entryCount, page.candidateCount))
            }.padding(12)
          }
        }.frame(minWidth: 260, idealWidth: 320)
        inspector.frame(minWidth: 400, maxHeight: .infinity, alignment: .topLeading)
      }.frame(maxHeight: .infinity)
      Divider()
      HStack {
        Button("Undo Staged Change") { Task { await model.undoStaging() } }
          .disabled(model.batchProjection == nil || model.isSaveUnresolved)
        Button("Discard Draft…", role: .destructive) { model.isConfirmingDiscard = true }
          .disabled(!model.isDiscardEnabled)
        Spacer()
        if model.draft != nil {
          Text(model.isDraftDirty ? "Draft not yet persisted" : "Draft saved locally").font(
            .caption)
        }
        Button(
          model.batchProjection == nil
            ? "Save Changes" : "Save Changes (\(model.stagedItems.count))"
        ) { Task { await model.save() } }
        .disabled(!model.isSaveEnabled)
      }.padding(12)
    }
  }

  private func candidateRow(_ candidate: MemoryReviewCandidate) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(MemoryDocument.reviewText(candidate.change.after)).lineLimit(3)
      Text(model.scopeLabel(path: candidate.change.path)).font(.caption).foregroundStyle(.secondary)
      if candidate.disposition == .approved { Text("Saved").foregroundStyle(.secondary) }
      if candidate.disposition == .rejected { Text("Dismissed").foregroundStyle(.secondary) }
    }.tag(NativeMemorySelection.candidate(candidate.change.id.rawValue))
  }

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 12) {
      if case .recovery = model.selection {
        Text("Recovery Required").font(.headline)
      } else if model.isSaveUnresolved || model.isRetainedSaveRecoverable {
        Text(model.isSaveUnresolved ? model.message : "Draft requires reconciliation").font(
          .headline)
        Button("Recover Save") { Task { await model.recoverSave() } }
      } else {
        editorInspector
      }
      DisclosureGroup("Details") { details.frame(maxHeight: 240) }
    }.padding(20)
  }

  @ViewBuilder private var editorInspector: some View {
    let owner = model.editorOwner
    HStack {
      Text(model.isAmendingSuggestion ? "Edit Suggestion" : model.selectedItem?.title ?? "Memory")
        .font(.title2.bold())
      Spacer()
      if let item = model.selectedItem {
        Button("Remove", role: .destructive) { Task { await model.removeItem(item.itemID) } }
      }
    }
    if let path = model.selectedMemoryPath {
      Text(model.scopeLabel(path: path)).font(.callout).foregroundStyle(.secondary)
    }
    if model.isEditing {
      Picker("View", selection: $model.isShowingDiff) {
        Text("Editor").tag(false)
        Text("Diff").tag(true)
      }.pickerStyle(.segmented)
      if !model.isShowingDiff {
        TextEditor(
          text: Binding(
            get: { model.editorText },
            set: { model.setEditorText($0, owner: owner) })
        ).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.2))
        TextField(
          "Change reason",
          text: Binding(
            get: { model.editorReason },
            set: { model.setEditorReason($0, owner: owner) }))
        HStack {
          Button(model.isAmendingSuggestion ? "Preview Amendment" : "Stage Edit") {
            Task { await model.stageEditor() }
          }
          if model.isExistingEntry {
            Button("Stage Deletion", role: .destructive) { Task { await model.deleteEntry() } }
              .disabled(model.editorReason.isEmpty)
          }
        }
      } else {
        diff
      }
    } else if model.presentation != nil || model.selectedItem != nil {
      diff
    } else if let candidate = model.selectedCandidate {
      PlainTextView(text: MemoryDocument.reviewText(candidate.change.after))
    } else if !model.editorText.isEmpty {
      PlainTextView(text: model.editorText)
    } else {
      Text(model.reviewEmptyMessage).foregroundStyle(.secondary).frame(
        maxWidth: .infinity, alignment: .topLeading)
    }
    if let shown = model.presentation {
      if model.isAmendingSuggestion && !model.isShowingDiff {
        PlainTextView(text: "FINAL RESULT\n" + MemoryDocument.reviewText(shown.after)).frame(
          height: 140)
      }
      Button(model.selectedCandidate == nil ? "Stage Confirm Reviewed" : "Stage Acceptance") {
        if model.selectedCandidate == nil {
          Task { await model.stageShown() }
        } else {
          model.submitReviewAction(.accept)
        }
      }.disabled(
        model.selectedCandidate == nil
          ? !model.isStageShownEnabled : !model.isReviewActionEnabled(.accept)
      )
      .help(model.selectedCandidate == nil ? "Stage Confirm Reviewed" : "Stage Acceptance (⌘↩)")
    }
    if let candidate = model.selectedCandidate,
      [.pending, .deferred].contains(candidate.disposition)
    {
      HStack {
        Button("Edit Suggestion") { Task { await model.editSuggestion() } }
          .disabled(model.presentation == nil || !model.isReviewTransitionEnabled)
        Button("Decide Later") { model.submitReviewAction(.decideLater) }
          .disabled(!model.isReviewActionEnabled(.decideLater))
          .help("Decide Later (⌘⇧D)")
        Button("Dismiss", role: .destructive) {
          model.submitReviewAction(.dismiss)
        }.disabled(!model.isReviewActionEnabled(.dismiss))
          .help("Dismiss (⌘⇧X)")
      }
    }
    if case .entry(let path, let start) = model.selection,
      let entry = model.visibleEntries.first(where: { $0.path == path && $0.locator.start == start }
      ), entry.isMutable
    {
      Button("Confirm Reviewed…") { Task { await model.confirmReviewed(entry) } }
        .disabled(!model.isReviewTransitionEnabled)
    }
  }

  private var diff: some View {
    PlainTextView(
      text: {
        if let shown = model.presentation {
          let original =
            model.selectedCandidate.map {
              "ORIGINAL SUGGESTION\n" + MemoryDocument.reviewText($0.change.after) + "\n\n"
            } ?? ""
          return original + "BEFORE\n" + MemoryDocument.reviewText(shown.before)
            + "\n\nFINAL RESULT\n" + MemoryDocument.reviewText(shown.after)
        }
        if case .manual(let intent) = model.selectedItem?.intent {
          return "BEFORE\n" + MemoryDocument.reviewText(Data((intent.request.expected ?? "").utf8))
            + "\n\nAFTER\n"
            + MemoryDocument.reviewText(Data((intent.request.replacement ?? "Deleted").utf8))
        }
        return model.editorText
      }())
  }

  private var details: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if let failure = model.failure { Text(failure).textSelection(.enabled) }
        if let failure = model.draftFailure { Text(failure).textSelection(.enabled) }
        if let path = model.selectedMemoryPath {
          Text(path).textSelection(.enabled)
          ForEach(model.configuredProjectDirectories(path: path), id: \.self) { directory in
            Text(directory).textSelection(.enabled)
          }
        }
        if let candidate = model.selectedCandidate {
          Text(candidate.limitation ?? "")
          PlainTextView(
            text: String(decoding: candidate.change.after, as: UTF8.self)
              + "\n\nREASON\n" + candidate.change.reason
              + "\n\nSOURCES\n" + candidate.change.sources.map(\.exactText).joined(separator: "\n")
              + "\n\nRECORDED DIRECTORIES\n"
              + Set(candidate.change.sources.compactMap(\.projectScope)).sorted().joined(
                separator: "\n")
              + "\n\nCONTRADICTIONS\n" + String(describing: candidate.change.contradictions)
          ).frame(height: 140)
        }
        if let shown = model.presentation {
          PlainTextView(
            text: shown.path + "\n" + shown.digest.rawValue + "\n\n"
              + String(decoding: shown.after, as: UTF8.self)
          ).frame(height: 140)
        }
        if let outcome = model.saveOutcome {
          Text(String(describing: outcome)).textSelection(.enabled)
        }
        if let draft = model.draft {
          Text("\(draft.draftID) · \(draft.baseCommit) · \(draft.revision)").textSelection(.enabled)
          if model.batchProjection == nil {
            PlainTextView(
              text: String(decoding: (try? JSONEncoder().encode(draft)) ?? Data(), as: UTF8.self)
            ).frame(height: 160)
          }
        }
        if let active = model.batchProjection, let retained = model.retainedDraft,
          retained.draftID != active.draft.draftID
        {
          PlainTextView(
            text: String(decoding: (try? JSONEncoder().encode(retained)) ?? Data(), as: UTF8.self)
          ).frame(height: 160)
        }
        Text(model.editorPath).textSelection(.enabled)
        Button("Reveal Checkout in Finder") { Task { await model.revealMemory() } }
        if case .recovery(let saveID) = model.selection,
          let recovery = model.draftRecoveries.first(where: { $0.failure.saveID == saveID })
        {
          Text(recovery.failure.description).textSelection(.enabled)
          Text("\(recovery.draftID) · revision \(recovery.revision)").textSelection(.enabled)
          if let draft = model.draftRecoveryDetails {
            PlainTextView(
              text: String(decoding: (try? JSONEncoder().encode(draft)) ?? Data(), as: UTF8.self)
            ).frame(height: 160)
          }
        }
        ForEach(model.drafts, id: \.draftID) { draft in
          Text("\(draft.draftID) · revision \(draft.revision)").textSelection(.enabled)
          Button(
            model.draftRecoveries.isEmpty
              ? "Recover Draft" : "Open Manual Draft; Keep Recovery Pending"
          ) {
            Task { await model.restore(draft) }
          }.disabled(!model.isDraftRestorationEnabled(draft))
        }
      }.font(.system(.caption, design: .monospaced))
    }
  }
}

extension ManagedMemoryEntry {
  var nativeID: String { "\(path):\(locator.start):\(locator.end)" }
}

extension MemoryBatchItem {
  var title: String {
    switch intent {
    case .manual(let intent): intent.request.operation.rawValue.capitalized + " Memory"
    case .confirmReviewed: "Confirm Reviewed"
    case .candidate(let intent):
      switch intent.choice {
      case .accept: intent.amendment == nil ? "Accept Suggestion" : "Amended Suggestion"
      case .deferCandidate: "Decide Later"
      case .reject: "Dismiss Suggestion"
      }
    }
  }
}
