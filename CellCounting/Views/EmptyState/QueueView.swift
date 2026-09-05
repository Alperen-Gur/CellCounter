import SwiftUI

struct QueueEmpty: View {
    @Bindable var state: AppState
    @State private var error: String?
    @State private var selectedJobId: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Processing").font(.title2.weight(.semibold))
                    Text("Review completed images while the next image processes. Jobs are saved on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import images…") { state.view = .home }
            }
            if let message = state.jobScheduler.persistenceError ?? error {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if TrainingService.isTrainingActive {
                Label("Training is using the analysis engine. Queued jobs will start when it finishes.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !state.jobScheduler.isLoaded { ProgressView("Restoring processing queue…") }
            else if state.jobScheduler.jobs.isEmpty {
                EmptyStateView(title: "No processing jobs", subtitle: "Import images, preview your settings, then process a batch.", symbol: "tray")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.jobScheduler.jobs.reversed()) { job in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(job.title).font(.headline)
                                    Spacer()
                                    Text(job.status.title).foregroundStyle(job.status == .failed ? .red : .secondary)
                                }
                                ProgressView(value: job.progress)
                                HStack {
                                    Text("\(job.completedCount) of \(job.items.count) complete" + (job.failedCount > 0 ? " · \(job.failedCount) failed" : ""))
                                    Spacer()
                                    if let remaining = job.estimatedRemainingSeconds, job.status == .running {
                                        Text("About \(max(1, Int(ceil(remaining / 60)))) min remaining")
                                    }
                                }.font(.callout).foregroundStyle(.secondary)
                                if state.jobScheduler.activeJobId == job.id {
                                    Text(state.processingStageLine.isEmpty ? "Preparing image…" : state.processingStageLine)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text("\(job.importOnly ? "Import only" : job.settings.modelName) · \(job.settings.pxPerUm.formatted()) px/µm · \(job.settings.zProjection) Z")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Open batch") { state.openBatch(id: job.batchId) }
                                        .disabled(!job.items.contains(where: { $0.imageId != nil }))
                                    if job.status == .draft {
                                        Button("Continue setup") { state.analysisSetupJobId = job.id }
                                    }
                                    if [.running, .queued].contains(job.status) {
                                        Button("Pause after image") { Task { await state.jobScheduler.pause(job.id) } }
                                    }
                                    if [.paused, .cancelled].contains(job.status) {
                                        Button("Resume") { action { try await state.jobScheduler.resume(job.id) } }
                                    }
                                    if job.failedCount > 0, ![.running, .pausing].contains(job.status) {
                                        Button("Retry failed") { action { try await state.jobScheduler.retryFailures(job.id) } }
                                    }
                                    Spacer()
                                    if [.running, .queued, .pausing].contains(job.status) {
                                        Button("Cancel", role: .destructive) { Task { await state.jobScheduler.cancel(job.id) } }
                                    } else {
                                        Button("Remove job") { action { try await state.jobScheduler.remove(job.id) } }
                                            .help("Remove the queue entry. Imported images and results remain in the library.")
                                    }
                                }
                                if job.failedCount > 0 {
                                    DisclosureGroup("Failed images") {
                                        ForEach(job.items.filter { $0.status == .failed }) { item in
                                            HStack(alignment: .top) {
                                                Text(item.fileName).frame(width: 180, alignment: .leading)
                                                Text(item.error ?? "Analysis failed").foregroundStyle(.secondary)
                                            }.font(.caption).padding(.vertical, 3)
                                        }
                                    }
                                }
                            }.padding(16).background(Tokens.bgSunken).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedJobId == job.id ? Color.accentColor : .clear, lineWidth: 1))
                                .contentShape(Rectangle()).onTapGesture { selectedJobId = job.id }
                        }
                    }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Tokens.bg)
            .focusedSceneValue(\.cellCounterShortcuts, shortcutActions)
    }
    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        actions.newItem = { state.view = .home }
        guard let job = state.jobScheduler.jobs.first(where: { $0.id == selectedJobId })
                ?? state.jobScheduler.jobs.first(where: { $0.id == state.jobScheduler.activeJobId })
                ?? state.jobScheduler.jobs.last else { return actions }
        if job.items.contains(where: { $0.imageId != nil }) { actions.openSelection = { state.openBatch(id: job.batchId) } }
        if job.status == .draft { actions.run = { state.analysisSetupJobId = job.id } }
        if [.paused, .cancelled].contains(job.status) {
            actions.run = { action { try await state.jobScheduler.resume(job.id) } }
            actions.pauseResume = actions.run
        }
        if job.status == .failed { actions.run = { action { try await state.jobScheduler.retryFailures(job.id) } } }
        if [.running, .queued].contains(job.status) { actions.pauseResume = { Task { await state.jobScheduler.pause(job.id) } } }
        if [.running, .queued, .pausing].contains(job.status) {
            actions.cancel = { Task { await state.jobScheduler.cancel(job.id) } }
        } else {
            actions.deleteSelection = { action { try await state.jobScheduler.remove(job.id) } }
        }
        return actions
    }
    private func action(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation(); error = nil } catch { self.error = error.localizedDescription } }
    }
}

struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Tokens.textQuaternary.opacity(0.7))
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
