import SwiftUI
import AppKit

// MARK: — Pass-17: Data models for the duplicate import session

/// One file in a drop session that already exists in the library.
struct DuplicateCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let hash: String
    let existingRecord: ImageRecord
}

/// Holds the entire context for one drop session that had at least one duplicate.
/// Created by AppState.importAndAnalyze, read by DuplicateImportSheet.
final class DuplicateImportSession {
    let allURLs: [URL]
    let condition: String?
    let duplicates: [DuplicateCandidate]
    /// Called by the sheet when the user confirms which URLs to actually import.
    let onProceed: ([URL]) -> Void

    init(allURLs: [URL], condition: String?, duplicates: [DuplicateCandidate],
         onProceed: @escaping ([URL]) -> Void) {
        self.allURLs = allURLs
        self.condition = condition
        self.duplicates = duplicates
        self.onProceed = onProceed
    }

    /// The set of duplicate URLs (for quick membership check).
    var duplicateURLs: Set<URL> { Set(duplicates.map(\.url)) }

    /// Non-duplicate files (will always be imported if the user confirms).
    var nonDuplicateURLs: [URL] { allURLs.filter { !duplicateURLs.contains($0) } }
}

// MARK: — Per-row decision

/// What the user chose for a single duplicate file.
enum DuplicateDecision {
    case skip           // Don't import — use existing
    case importAnyway   // Create a new ImageRecord (original behavior)
    case reRun          // Re-run detection on the existing record
}

// MARK: — Sheet view

/// Presented when at least one dropped file already exists in the library.
/// Shows a list of duplicate groups and lets the user decide per-file (or globally).
struct DuplicateImportSheet: View {
    @Bindable var state: AppState
    let session: DuplicateImportSession

    /// Per-file decision, keyed by DuplicateCandidate.id.
    @State private var decisions: [UUID: DuplicateDecision] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.top, 24)
                let n = session.duplicates.count
                Text(n == 1 ? "This file is already imported" : "\(n) files are already imported")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text("Choose what to do for each duplicate below.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .padding(.bottom, 16)

            Divider()

            // List of duplicates
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(session.duplicates) { candidate in
                        DuplicateRow(
                            candidate: candidate,
                            decision: Binding(
                                get: { decisions[candidate.id] ?? .skip },
                                set: { decisions[candidate.id] = $0 }
                            )
                        )
                        Divider().padding(.horizontal, 20)
                    }
                }
            }
            .frame(maxHeight: 320)

            Divider()

            // Non-duplicates summary
            if !session.nonDuplicateURLs.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.success)
                        .font(.system(size: 12))
                    Text("\(session.nonDuplicateURLs.count) new file\(session.nonDuplicateURLs.count == 1 ? "" : "s") will always be imported.")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }

            Divider()

            // Bulk actions + confirm row
            HStack(spacing: 10) {
                Button("Skip all duplicates") {
                    for d in session.duplicates { decisions[d.id] = .skip }
                }
                .appButton(.standard, size: .sm)

                Button("Import all anyway") {
                    for d in session.duplicates { decisions[d.id] = .importAnyway }
                }
                .appButton(.standard, size: .sm)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .appButton(.standard, size: .sm)

                Button("Confirm") {
                    confirm()
                }
                .appButton(.primary, size: .sm)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .background(Tokens.bg)
        .onAppear {
            // Default: skip all duplicates
            for d in session.duplicates { decisions[d.id] = .skip }
        }
    }

    private func dismiss() {
        state.showDuplicateImportSheet = false
        state.pendingDuplicateSession = nil
    }

    private func confirm() {
        var urlsToImport: [URL] = session.nonDuplicateURLs

        for candidate in session.duplicates {
            let decision = decisions[candidate.id] ?? .skip
            switch decision {
            case .skip:
                break // Nothing to do — existing record stays as-is
            case .importAnyway:
                urlsToImport.append(candidate.url)
            case .reRun:
                // Re-run detection on the existing record without creating a new one.
                state.reRunDetection(on: candidate.existingRecord)
                // Navigate to the existing batch so the user sees progress.
                if let batch = candidate.existingRecord.batch {
                    state.currentBatchId = batch.id
                    let sorted = batch.images.sorted { $0.importedAt < $1.importedAt }
                    if let idx = sorted.firstIndex(where: { $0.id == candidate.existingRecord.id }) {
                        state.currentImageIdx = idx
                    }
                }
            }
        }

        state.showDuplicateImportSheet = false
        state.pendingDuplicateSession = nil

        if !urlsToImport.isEmpty {
            // Only proceed if there's a usable detector (already checked in importAndAnalyze,
            // but guard here since the user may have uninstalled the model during the prompt).
            if let svc = state.detectorRegistry.detector(for: state.activeModelId, models: state.models) {
                state.proceedWithImport(urls: urlsToImport,
                                        condition: session.condition,
                                        svc: svc)
            }
        }
    }
}

// MARK: — Row for a single duplicate candidate

private struct DuplicateRow: View {
    let candidate: DuplicateCandidate
    @Binding var decision: DuplicateDecision

    @State private var thumb: NSImage? = nil

    private var existing: ImageRecord { candidate.existingRecord }

    private var importedDateString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: existing.importedAt)
    }

    private var batchName: String { existing.batch?.displayName ?? "unknown batch" }
    private var cellCount: Int { existing.detection?.cells.count ?? 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Thumbnail
            ZStack {
                if let img = thumb {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Tokens.bgSunken)
                        .frame(width: 56, height: 56)
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Tokens.textQuaternary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                Text("Imported \(importedDateString) · batch \"\(batchName)\" · \(cellCount) cells detected")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            // Decision picker
            VStack(alignment: .trailing, spacing: 6) {
                DecisionButton(label: "Open existing analysis",
                               systemImage: "arrow.right.circle",
                               selected: decision == .skip) {
                    decision = .skip
                }
                DecisionButton(label: "Re-run detection",
                               systemImage: "arrow.clockwise.circle",
                               selected: decision == .reRun) {
                    decision = .reRun
                }
                DecisionButton(label: "Import anyway",
                               systemImage: "plus.circle",
                               selected: decision == .importAnyway) {
                    decision = .importAnyway
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onAppear { loadThumb() }
    }

    private func loadThumb() {
        let url = existing.thumbURL
        Task.detached(priority: .utility) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { thumb = img }
        }
    }
}

// MARK: — Small inline radio-style button

private struct DecisionButton: View {
    let label: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    @Environment(AppTheme.self) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? theme.accentColor : Tokens.textTertiary)
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? theme.accentColor : Tokens.textSecondary)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? theme.accentColor : Tokens.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

