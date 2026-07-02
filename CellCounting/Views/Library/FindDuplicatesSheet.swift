import SwiftUI
import AppKit

/// Pass-17: Shows groups of 2+ images that share the same fileHash.
/// Each group has a "Delete N–1 oldest" per-row action and a
/// "Delete all duplicates (keep newest)" bulk action.
struct FindDuplicatesSheet: View {
    @Bindable var state: AppState
    let onDismiss: () -> Void

    @State private var groups: [[ImageRecord]] = []
    @State private var isLoading = false

    private var totalDuplicatesToDelete: Int {
        groups.reduce(0) { $0 + max(0, $1.count - 1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find Duplicates")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    if isLoading {
                        Text("Scanning library…")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.textSecondary)
                    } else if groups.isEmpty {
                        Text("No duplicates found.")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.textSecondary)
                    } else {
                        Text("\(groups.count) duplicate group\(groups.count == 1 ? "" : "s") · \(totalDuplicatesToDelete) extra cop\(totalDuplicatesToDelete == 1 ? "y" : "ies")")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.textSecondary)
                    }
                }
                Spacer()
                Button("Close") { onDismiss() }
                    .appButton(.standard, size: .sm)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            if isLoading {
                VStack {
                    ProgressView()
                        .controlSize(.regular)
                        .padding(.top, 40)
                    Text("Scanning for duplicates…")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textSecondary)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Tokens.textTertiary)
                    Text("No duplicate images found in your library.")
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // List of duplicate groups
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(groups.indices, id: \.self) { idx in
                            DuplicateGroupRow(
                                group: groups[idx],
                                state: state,
                                onDeleteOldest: {
                                    deleteOldest(in: groups[idx])
                                }
                            )
                            if idx < groups.count - 1 {
                                Divider().padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Divider()

                // Bulk action footer
                HStack {
                    Spacer()
                    Button {
                        deleteAllDuplicates()
                    } label: {
                        HStack(spacing: 5) {
                            Icon("trash", size: 12)
                            Text("Delete all duplicates (keep newest of each)")
                        }
                    }
                    .appButton(.danger, size: .sm)
                    .disabled(groups.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 620, height: 480)
        .background(Tokens.bg)
        .onAppear { reload() }
    }

    // MARK: — Helpers

    private func reload() {
        groups = state.repos.duplicateGroups()
    }

    /// Keep the newest (latest importedAt), delete the rest in `group`.
    private func deleteOldest(in group: [ImageRecord]) {
        guard group.count >= 2 else { return }
        let sorted = group.sorted { $0.importedAt > $1.importedAt } // newest first
        let toDelete = Array(sorted.dropFirst())

        let alert = NSAlert()
        alert.messageText = "Delete \(toDelete.count) older cop\(toDelete.count == 1 ? "y" : "ies") of \"\(group.first?.fileName ?? "this file")\"?"
        alert.informativeText = "The newest import will be kept. Detections and corrections will be removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }

        for img in toDelete { state.repos.deleteImage(img) }
        NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
        reload()
    }

    /// Keep the newest of each hash group, delete everything else.
    private func deleteAllDuplicates() {
        let toDelete: [ImageRecord] = groups.flatMap { group -> [ImageRecord] in
            let sorted = group.sorted { $0.importedAt > $1.importedAt }
            return Array(sorted.dropFirst())
        }
        guard !toDelete.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(toDelete.count) duplicate image\(toDelete.count == 1 ? "" : "s")?"
        alert.informativeText = "The newest import of each file will be kept. All older copies (and their detections) will be deleted. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete \(toDelete.count) duplicate\(toDelete.count == 1 ? "" : "s")")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }

        for img in toDelete { state.repos.deleteImage(img) }
        NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
        reload()
    }
}

// MARK: — Row for one duplicate group

private struct DuplicateGroupRow: View {
    let group: [ImageRecord]
    @Bindable var state: AppState
    let onDeleteOldest: () -> Void

    @State private var thumbs: [UUID: NSImage] = [:]

    private var oldest: [ImageRecord] {
        group.sorted { $0.importedAt < $1.importedAt }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Stack of thumbnails (max 3 shown)
            ZStack {
                ForEach(Array(oldest.prefix(3).enumerated().reversed()), id: \.element.id) { idx, img in
                    thumbView(img)
                        .offset(x: CGFloat(idx) * 4, y: CGFloat(idx) * -4)
                }
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.first?.fileName ?? "")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)

                Text("\(group.count) copies · in batch\(batchNames().count == 1 ? "" : "es") \(batchNames().joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(2)

                // Rows per copy
                ForEach(oldest, id: \.id) { img in
                    HStack(spacing: 6) {
                        Text(importedDateString(img))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                        if let det = img.detection {
                            Text("\(det.cells.count) cells")
                                .font(.system(size: 10))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                        if img.id == oldest.last?.id {
                            Text("newest")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Tokens.textQuaternary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Tokens.bgSunken))
                        }
                    }
                }
            }

            Spacer()

            Button {
                onDeleteOldest()
            } label: {
                HStack(spacing: 4) {
                    Icon("trash", size: 11)
                    Text("Delete \(group.count - 1) oldest")
                }
            }
            .appButton(.danger, size: .sm)
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onAppear { loadThumbs() }
    }

    private func thumbView(_ img: ImageRecord) -> some View {
        ZStack {
            if let t = thumbs[img.id] {
                Image(nsImage: t)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Tokens.bgSunken)
                    .frame(width: 56, height: 56)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5)
        )
    }

    private func loadThumbs() {
        let pairs: [(UUID, URL)] = group.map { ($0.id, $0.thumbURL) }
        Task.detached(priority: .utility) {
            var loaded: [UUID: NSImage] = [:]
            for (id, url) in pairs {
                if let img = NSImage(contentsOf: url) { loaded[id] = img }
            }
            await MainActor.run { thumbs = loaded }
        }
    }

    private func batchNames() -> [String] {
        let names = group.compactMap { $0.batch?.displayName }
        return Array(Set(names)).sorted()
    }

    private func importedDateString(_ img: ImageRecord) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: img.importedAt)
    }
}
