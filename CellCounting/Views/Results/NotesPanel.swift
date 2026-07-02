import SwiftUI
import SwiftData

// MARK: — Notes panel (Pass-18, Lane N)

/// Freeform notes attached to the currently-loaded image. Lets the user record
/// donor / passage / sample / experimental observations that filenames can't
/// carry — the friction-point in batches imported from multiple donors with
/// similar filenames. Writes back to `ImageRecord.notes` directly.
///
/// Auto-saves with a ~500 ms debounce via a `Task.sleep` cancellation pattern
/// (no Timer): each text change cancels the in-flight save Task and schedules
/// a new one. This keeps the SwiftData store from being flogged on every
/// keystroke while still landing the write within half a second of the user
/// pausing.
///
/// Hidden entirely when there's no current image (e.g. transient state during
/// an image switch), to avoid binding to a nil target.
struct NotesPanel: View {
    @Bindable var state: AppState

    /// Local mirror of `currentImage?.notes`. We hold this separately so the
    /// TextEditor binding is stable across image switches — writing into the
    /// record happens in `commit()` after the debounce window.
    @State private var draft: String = ""
    /// Tracks which image our `draft` belongs to so we can reload when the
    /// user switches images without losing or cross-contaminating notes.
    @State private var draftImageId: UUID? = nil
    /// In-flight debounce task — cancelled on every text edit so only the
    /// final pause triggers a save.
    @State private var saveTask: Task<Void, Never>? = nil
    @FocusState private var focused: Bool

    private var currentImage: ImageRecord? { state.currentImage }

    var body: some View {
        if currentImage == nil {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                SectionHeader(
                    title: "Notes",
                    trailing: AnyView(charCountLabel)
                )

                ZStack(alignment: .topLeading) {
                    if draft.isEmpty && !focused {
                        Text("Sample, donor, passage, observations…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Tokens.textQuaternary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Tokens.text)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .frame(minHeight: 88, maxHeight: 160)
                }
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.bgSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .onAppear { syncDraftFromImage() }
            .onChange(of: state.currentImage?.id) { _, _ in
                // Image switched — flush any pending save against the previous
                // image, then reload from the new one.
                flushPendingSave()
                syncDraftFromImage()
            }
            .onChange(of: draft) { _, newValue in
                scheduleSave(newValue)
            }
            .onDisappear { flushPendingSave() }
        }
    }

    @ViewBuilder
    private var charCountLabel: some View {
        if !draft.isEmpty {
            Text("\(draft.count) char\(draft.count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.textTertiary)
        } else {
            EmptyView()
        }
    }

    /// Reload the draft from the current image's `notes`. Called on appear and
    /// whenever the user switches images.
    private func syncDraftFromImage() {
        guard let image = currentImage else {
            draft = ""
            draftImageId = nil
            return
        }
        draft = image.notes ?? ""
        draftImageId = image.id
    }

    /// Debounced save: cancel any in-flight task, then schedule a new one that
    /// commits the text after ~500 ms of inactivity. Cancellation pattern uses
    /// `Task.sleep` so the cancelled task throws and we never write stale text.
    private func scheduleSave(_ text: String) {
        // Only persist if the draft still belongs to the same image we synced
        // from — guards against the cross-image race during an image switch.
        guard let image = currentImage, image.id == draftImageId else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return  // cancelled — newer keystroke landed
            }
            commit(text, to: image)
        }
    }

    /// Synchronously flush any pending save (e.g. on image switch or disappear).
    private func flushPendingSave() {
        guard let task = saveTask else { return }
        task.cancel()
        saveTask = nil
        // Commit the current draft against the image it was synced from — but
        // only if the image still exists in this state graph.
        if let id = draftImageId,
           let image = state.repos.allImages().first(where: { $0.id == id }) {
            commit(draft, to: image)
        }
    }

    /// Persist `text` into `image.notes`. Stores nil when the field is empty
    /// so the column doesn't carry empty-string noise (matches existing
    /// nil-default patterns elsewhere — `confidenceOverride`, `condition`).
    private func commit(_ text: String, to image: ImageRecord) {
        let normalized: String? = text.isEmpty ? nil : text
        if image.notes == normalized { return }
        image.notes = normalized
        try? state.repos.context.save()
    }
}
