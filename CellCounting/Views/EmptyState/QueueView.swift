import SwiftUI

/// Empty state for the processing Queue (`state.view == .queue`).
///
/// Researcher feedback (#11): "I couldn't understand what the Queue tab
/// does." The previous copy — title "Queue is empty" plus "Active analyses
/// appear here. Drop a folder to fill it up." — never actually said what a
/// "queue" is, and "Drop a folder" implied this screen accepts drag-and-drop
/// itself, which it doesn't (no `.onDrop` here; the only drop zone is on
/// Home). Rewritten so the empty state teaches the concept on its own: the
/// Queue is where analysis jobs sit while pending or running, each with a
/// status (queued / running / done / error — see `BatchRowStatus` in
/// Domain/Batch.swift), so multiple detections in flight can be tracked from
/// one screen. See the audit's REPORTED section for a separate, structural
/// finding: this view currently has no navigation entry point at all.
struct QueueEmpty: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Tokens.textQuaternary.opacity(0.7))
                .padding(.bottom, 4)
            Text("Queue is empty")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("The Queue lists analysis jobs that are pending or currently running, along with each job's status, so you can track detection progress in one place.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text("Nothing is queued right now. Start an analysis from Home and it will appear here while it processes.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Back to Home") { state.view = .home }
                .appButton(.primary, size: .sm)
                .padding(.top, 4)
        }
        .padding(.vertical, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
