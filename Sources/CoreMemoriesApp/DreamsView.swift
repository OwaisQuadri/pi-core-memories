import CoreMemories
import SwiftUI

struct DreamsView: View {
  @ObservedObject var model: AppModel
  @State private var isShowingDetails = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label("Find memory suggestions", systemImage: "moon.stars").font(.title2.bold())
          Spacer()
          if model.isDreamRunning {
            ProgressView().controlSize(.small).accessibilityLabel(model.dreamPhase)
            Button("Stop Finding Suggestions") { model.cancelDream() }.fixedSize()
          }
        }
        Text(statusTitle).font(.headline)
        if !model.dreamDetail.isEmpty, model.invocationStatus?.isPublicationBlocked != true,
          model.dreamPhase != "Status unavailable"
        {
          Text(model.dreamDetail).textSelection(.enabled)
        }
        DreamQueueView(model: model)
        if !model.isDreamRunning {
          HStack {
            if model.savedRecoveryRunID != nil {
              Button("Prepare Saved Suggestions…") {
                Task { await model.prepareSavedRecovery() }
              }.fixedSize()
            } else if model.resumableRun != nil {
              Button("Continue Saved Work") { model.run(.start) }.fixedSize()
            } else if model.invocationStatus?.reason == "invalidDecision" {
              Button("Replace Invalid Reply…") { model.isConfirmingReplacement = true }.fixedSize()
            } else if ["interruptedCall", "callInterrupted", "callbackFailure"].contains(
              model.invocationStatus?.reason ?? "")
            {
              Button("Retry Interrupted Call…") { model.isConfirmingRetry = true }.fixedSize()
            } else {
              Button("Find Suggestions") { model.run(.start) }.fixedSize()
            }
            Button(model.reviewActionTitle) { model.section = "Review" }.fixedSize()
            Menu("Other Actions") {
              Button("Find Suggestions in One Batch") { model.run(.start) }
              Button("Find Suggestions in All Waiting Batches") { model.run(.all) }
              Divider()
              Button("Retry Interrupted Call…") { model.isConfirmingRetry = true }
                .disabled(model.invocationStatus?.isPublicationBlocked == true)
              Button("Replace Invalid Reply…") { model.isConfirmingReplacement = true }
                .disabled(model.invocationStatus?.isPublicationBlocked == true)
            }.fixedSize()
            Spacer()
          }
          if model.invocationStatus?.isPublicationBlocked != true {
            Text(
              "Finding suggestions uses your selected model and may incur a charge. It never changes saved memories. Review suggestions and choose Save into Memory to apply them."
            )
            .font(.callout).foregroundStyle(.secondary)
          }
        }
        DisclosureGroup("Details", isExpanded: $isShowingDetails) {
          details
        }
      }.padding(20)
    }
    .sheet(
      isPresented: Binding(
        get: { model.savedRecovery != nil },
        set: { if !$0 { Task { await model.cancelSavedRecovery() } } })
    ) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Prepare Saved Suggestions").font(.title2.bold())
        Text(
          "No model call or charge. Nothing is saved into memory now. Each memory needs a fresh preview and separate Save into Memory approval."
        )
        if let recovery = model.savedRecovery {
          Text("\(recovery.actionableCount) ready to review").font(.headline)
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              ForEach(recovery.suggestions, id: \.change.id) { suggestion in
                VStack(alignment: .leading, spacing: 6) {
                  Text(MemoryDocument.reviewText(suggestion.change.after))
                  Text(
                    MemoryScopeConfiguration.label(
                      path: suggestion.change.path, deviceKey: model.configuration.deviceKey)
                  )
                  .font(.caption).foregroundStyle(.secondary)
                  if let blocker = suggestion.blocker {
                    Text(blocker).foregroundStyle(.orange)
                  }
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          HStack {
            Spacer()
            Button("Cancel", role: .cancel) { Task { await model.cancelSavedRecovery() } }
            Button("Prepare for Review") { Task { await model.confirmSavedRecovery() } }
              .disabled(model.isBusy)
          }
        }
      }.padding(24).frame(width: 640, height: 520)
        .environment(\.isEnabled, true)
    }
    .alert("Retry Interrupted Call?", isPresented: $model.isConfirmingRetry) {
      Button("Cancel", role: .cancel) {}
      Button("Retry") { model.run(.retry) }
    } message: {
      Text(
        "This can make another billable call using the saved request and your current selection. It does not save suggestions into memory."
      )
    }
    .alert("Replace Invalid Reply?", isPresented: $model.isConfirmingReplacement) {
      Button("Cancel", role: .cancel) {}
      Button("Replace") { model.run(.replace) }
    } message: {
      Text(
        "The rejected reply is retained. A replacement can make another billable call and uses the same frozen validation rules. It does not save suggestions into memory."
      )
    }
  }

  private var statusTitle: String {
    if model.isDreamRunning { return model.dreamPhase }
    if let status = model.invocationStatus {
      switch status.status {
      case "completed": return "Conversation processing finished"
      case "noNewRecords": return "No new conversations to process"
      case "pending":
        return status.isPublicationBlocked
          ? "Saved suggestions are waiting" : "Saved work needs attention"
      default: return status.title
      }
    }
    if model.dreamPhase == "Status unavailable" { return model.dreamPhase }
    if let run = model.inspection?.runs.first, !run.isCompleted {
      return runTitle(run)
    }
    return model.dreamPhase == "Idle"
      ? "Ready to find suggestions in recent conversations" : model.dreamPhase
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.invocationStatus?.isPublicationBlocked == true
        || model.dreamPhase == "Status unavailable"
      {
        Text(model.dreamDetail).textSelection(.enabled)
      }
      if let detail = model.invocationStatus?.detail, !detail.isEmpty {
        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let unavailable = model.queueSnapshot?.unavailableReason {
        Text(unavailable).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      LabeledContent(
        "Requested model",
        value: [
          model.configuration.settings.provider ?? "Pi default",
          model.configuration.settings.modelID ?? "Pi default",
          model.configuration.settings.thinkingLevel ?? "Pi default",
        ].joined(separator: " / "))
      LabeledContent("Resolved model", value: model.resolvedSelection)
      if let date = model.invocationStatus?.observedAt {
        LabeledContent(
          "Last saved report", value: date.formatted(date: .abbreviated, time: .standard))
      }
      HSplitView {
        List {
          if model.inspection?.isBusy == true { Text("Another invocation is saving dream work") }
          if model.inspection?.isPresent == false { Text("No saved dream work") }
          ForEach(model.inspection?.runs ?? []) { run in
            DisclosureGroup {
              Text(run.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              ForEach(run.attempts) { attempt in
                VStack(alignment: .leading, spacing: 5) {
                  Text("Attempt \(attempt.number + 1) · \(attempt.status)").fontWeight(.medium)
                  Text("\(attempt.provider) / \(attempt.modelID) / \(attempt.thinkingLevel)")
                    .font(.caption).textSelection(.enabled)
                  if let diagnostic = attempt.diagnostic {
                    Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                  }
                }.padding(.vertical, 5)
              }
              ForEach(run.artifacts) { artifact in
                Button {
                  Task { await model.inspect(artifact) }
                } label: {
                  HStack {
                    Text(artifact.name)
                    Spacer()
                    Text(artifact.byteCount.formatted()).foregroundStyle(.secondary)
                  }
                }.buttonStyle(.plain)
              }
            } label: {
              VStack(alignment: .leading) {
                Text(runTitle(run)).fontWeight(.medium)
                if let generation = run.generation {
                  Text("Saved batch · generation \(generation)").font(.caption).monospacedDigit()
                }
                if let diagnostic = run.attempts.last?.diagnostic ?? run.diagnostic {
                  Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
              }
            }
          }
        }.frame(minWidth: 260, idealWidth: 320)
        VStack(alignment: .leading) {
          HStack {
            Text(model.selectedArtifact?.name ?? "Saved Artifacts").font(.headline)
            Spacer()
            Button("Reveal in Finder") { Task { await model.revealArtifact() } }.disabled(
              model.selectedArtifact == nil
            ).fixedSize()
          }
          PlainTextView(text: model.artifactText)
        }.padding(12).frame(minWidth: 300)
      }.frame(height: 320)
      if !model.dreamEvents.isEmpty {
        DisclosureGroup("Invocation Events") {
          PlainTextView(text: model.dreamEvents.joined(separator: "\n\n")).frame(height: 150)
        }
      }
    }.padding(.top, 12)
  }

  private func runTitle(_ run: SavedDreamRun) -> String {
    if model.invocationStatus?.runID == run.id {
      return model.invocationStatus?.isPublicationBlocked == true
        ? "Saved suggestions are waiting"
        : model.invocationStatus?.title ?? "Saved work needs attention"
    }
    if run.isCompleted { return "Processing completed" }
    switch run.attempts.last?.status {
    case "Reply valid": return "Saved suggestions are waiting"
    case "Rejected reply": return "Saved reply needs replacement"
    default: return "Saved work; completion not established"
    }
  }
}
