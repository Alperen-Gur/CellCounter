import Foundation
import Dispatch

/// How strongly macOS asked apps to give memory back.
nonisolated enum MemoryPressureLevel: String, Sendable, Comparable {
    case warning
    case critical

    private var rank: Int { self == .warning ? 0 : 1 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// UserInfo key of `.ccMemoryPressure` notifications.
    static let userInfoKey = "level"

    /// The level carried by a `.ccMemoryPressure` notification (warning when absent).
    init(notification: Notification) {
        let raw = notification.userInfo?[Self.userInfoKey] as? String
        self = raw.flatMap(Self.init(rawValue:)) ?? .warning
    }
}

extension Notification.Name {
    /// Posted on the main thread when macOS reports memory pressure. The
    /// userInfo carries `MemoryPressureLevel.userInfoKey` ("warning" or
    /// "critical"). Observers drop caches they can rebuild; they must never
    /// drop data that exists nowhere else.
    static let ccMemoryPressure = Notification.Name("ccMemoryPressure")
}

/// Where pressure events come from. Tests substitute a fake.
nonisolated protocol MemoryPressureSource: AnyObject {
    /// `handler` may be called from any thread.
    func start(handler: @escaping @Sendable (MemoryPressureLevel) -> Void)
    func stop()
}

nonisolated final class SystemMemoryPressureSource: MemoryPressureSource, @unchecked Sendable {
    private var source: DispatchSourceMemoryPressure?

    func start(handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            handler(source.data.contains(.critical) ? .critical : .warning)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

private nonisolated final class WeakMonitor: @unchecked Sendable {
    // Read only on the main actor.
    weak var monitor: MemoryPressureMonitor?
    @MainActor init(_ monitor: MemoryPressureMonitor) { self.monitor = monitor }
}

/// Reacts to macOS memory pressure by dropping caches that are rebuilt from
/// disk on demand. Nothing unsaved is ever dropped: every cache involved is a
/// copy of data that lives in the library or in the source files.
@MainActor
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    /// Events at the same or a lower level inside this window are ignored.
    /// An escalation to `.critical` is always handled.
    nonisolated static let defaultDebounce: TimeInterval = 10

    private let source: any MemoryPressureSource
    private let debounce: TimeInterval
    private let now: () -> Date
    private let purge: @MainActor (MemoryPressureLevel) -> Void
    private let center: NotificationCenter
    private var last: (date: Date, level: MemoryPressureLevel)?
    private var started = false

    private(set) var handledCount = 0
    private(set) var suppressedCount = 0

    init(source: any MemoryPressureSource = SystemMemoryPressureSource(),
         debounce: TimeInterval = MemoryPressureMonitor.defaultDebounce,
         now: @escaping () -> Date = Date.init,
         center: NotificationCenter = .default,
         purge: @escaping @MainActor (MemoryPressureLevel) -> Void = MemoryPurger.purge) {
        self.source = source
        self.debounce = max(0, debounce)
        self.now = now
        self.center = center
        self.purge = purge
    }

    func start() {
        guard !started else { return }
        started = true
        let target = WeakMonitor(self)
        source.start { level in
            Task { @MainActor in target.monitor?.handle(level) }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        source.stop()
    }

    /// Entry point for one pressure event.
    func handle(_ level: MemoryPressureLevel) {
        let date = now()
        if let last, date.timeIntervalSince(last.date) < debounce, level <= last.level {
            suppressedCount += 1
            return
        }
        last = (date, level)
        handledCount += 1
        // Observers (Workspace sessions) release their own memory first, then
        // the shared caches and workers.
        center.post(name: .ccMemoryPressure, object: nil,
                    userInfo: [MemoryPressureLevel.userInfoKey: level.rawValue])
        purge(level)
    }
}

/// The shared caches and workers released under pressure.
///
/// - warning: viewer bitmaps, decoded-cell cache, prompt-refinement grey
///   planes, idle assay worker (its Python-side cache goes with the process),
///   idle detection workers (including the prompt-refinement worker and the
///   embeddings it holds).
///   Workspace sessions drop reloadable planes that are not on screen.
/// - critical: also the thumbnail and review-preview caches, and Workspace
///   planes of visible layers (their displayed bitmaps stay).
///
/// A worker with a request in flight is never stopped.
@MainActor
enum MemoryPurger {
    static func purge(level: MemoryPressureLevel) {
        ImageLoader.purgeMemoryCaches(includingPreviews: level == .critical)
        // This cache holds decodes only; the open image re-decodes on demand.
        DecodedCellCache.shared.removeAll()
        // Grey planes for prompt refinement; the next click draws its image again.
        Task { await PromptImagePlaneCache.shared.removeAll() }
        Task { await AssayWorkerService.shared.purgeForMemoryPressure() }
        Task { await PersistentSidecarPool.shared.retireIdleWorkers() }
    }
}
