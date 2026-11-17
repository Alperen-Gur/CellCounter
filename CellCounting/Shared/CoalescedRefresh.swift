import Foundation

/// Turns change notifications into one refresh at a time.
///
/// Requests are recorded as "everything" or a set of image ids. A single
/// worker waits `delay`, takes everything requested so far, runs the most
/// recently passed `perform` (so it sees the view's latest inputs) and
/// repeats while new requests arrived meanwhile. A running refresh is never
/// cancelled by a new request (so a steady stream of notifications, such as
/// a running analysis, cannot starve it); `cancel()` stops it, for example
/// when the screen goes away.
@MainActor
final class CoalescedRefresh {
    typealias Perform = @MainActor (_ everything: Bool, _ imageIds: Set<UUID>) async -> Void

    private var everything = false
    private var imageIds: Set<UUID> = []
    private var perform: Perform?
    private var worker: Task<Void, Never>?

    /// Records a request for all rows (`imageId == nil`) or for one image.
    func request(_ imageId: UUID? = nil, delay: Duration = .milliseconds(250), perform: @escaping Perform) {
        if let imageId { imageIds.insert(imageId) } else { everything = true }
        self.perform = perform
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            while let self, self.everything || !self.imageIds.isEmpty {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                let all = self.everything
                let ids = self.imageIds
                self.everything = false
                self.imageIds = []
                await self.perform?(all, all ? [] : ids)
                if Task.isCancelled { return }
            }
            // Idle: release the closure (and the view state it captured).
            self?.perform = nil
            self?.worker = nil
        }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        everything = false
        imageIds = []
        perform = nil
    }

    /// The image id a `ccCorrectionsChanged` notification names, if any; nil
    /// means the change may touch any image.
    nonisolated static func imageId(of note: Notification) -> UUID? {
        note.object as? UUID
    }
}
