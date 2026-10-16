import Foundation
import AppKit
import Combine

/// Numeric aggregates only; no payload, IDs, paths, wall-clock timestamps or raw errors.
nonisolated enum LocalOperation: String, CaseIterable, Sendable {
    case imageImport = "image.import", imageDecode = "image.decode", imagePreview = "image.preview"
    case queueLoad = "queue.load", queueSave = "queue.save", queueProcess = "queue.process"
    case inference = "analysis.inference", assay = "analysis.assay"
    case reviewLoad = "review.load", reviewSave = "review.save"
    case storageRead = "storage.read", storageWrite = "storage.write"
    case exportPrepare = "export.prepare", eventLoop = "ui.event-loop"
}
nonisolated final class LocalPerformanceRecorder: @unchecked Sendable {
    static let shared = LocalPerformanceRecorder()
    private struct Metric {
        var count = 0, dropped = 0, failures = 0, unspecified = 0, pending = 0
        var total = 0.0, min = Double.infinity, max = 0.0
        var recent: [Double] = []
    }
    private let lock = NSLock()
    private var metrics: [LocalOperation: Metric] = [:]
    private var active = false, generation = 0
    private var started = 0.0, elapsed = 0.0, limit = 1800.0
    private func clock() -> Double { ProcessInfo.processInfo.systemUptime }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; if active && clock() - started >= limit { active = false; elapsed = limit }; return active }
    func start(minutes: Int = 30) { lock.lock(); defer { lock.unlock() }; limit = Double([10, 30, 120].contains(minutes) ? minutes : 30) * 60; generation += 1; metrics = [:]; elapsed = 0; started = clock(); active = true }
    func stop() { lock.lock(); defer { lock.unlock() }; if active { elapsed = Swift.min(limit, Swift.max(0, clock() - started)); active = false } }
    func clear() { lock.lock(); defer { lock.unlock() }; active = false; generation += 1; metrics = [:]; elapsed = 0 }
    /// A span carries no image identity. Calls while disabled retain nothing.
    func begin(_ operation: LocalOperation, elapsedMilliseconds: Double = 0) -> Span? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        if clock() - started >= limit { elapsed = limit; active = false; return nil }
        var metric = metrics[operation] ?? Metric(); metric.pending += 1; metrics[operation] = metric
        return Span(operation: operation, generation: generation, started: clock() - (elapsedMilliseconds.isFinite ? Swift.min(limit * 1000, Swift.max(0, elapsedMilliseconds)) / 1000 : 0))
    }
    final class Span: @unchecked Sendable {
        let operation: LocalOperation, generation: Int, started: Double
        private let lock = NSLock()
        private var ended = false
        init(operation: LocalOperation, generation: Int, started: Double) { self.operation = operation; self.generation = generation; self.started = started }
        func finish(success: Bool? = nil) {
            lock.lock(); let first = !ended; ended = true; lock.unlock()
            if first { LocalPerformanceRecorder.shared.finish(self, success: success) }
        }
    }
    private func finish(_ span: Span, success: Bool?) {
        lock.lock(); defer { lock.unlock() }
        guard active, generation == span.generation else { return }
        let duration = clock() - started
        if duration >= limit { elapsed = limit; active = false; return }
        var metric = metrics[span.operation] ?? Metric()
        metric.pending = Swift.max(0, metric.pending - 1)
        if metric.count < 100_000 {
            let ms = Swift.min(limit * 1000, Swift.max(0, (clock() - span.started) * 1000))
            metric.count += 1; if let success { if !success { metric.failures += 1 } } else { metric.unspecified += 1 }; metric.total += ms
            metric.min = Swift.min(metric.min, ms); metric.max = Swift.max(metric.max, ms)
            if metric.recent.count < 256 { metric.recent.append(ms) } else { metric.recent[(metric.count - 1) % 256] = ms }
        } else { metric.dropped += 1 }
        metrics[span.operation] = metric
    }
    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        let duration = Swift.min(limit, active ? Swift.max(0, clock() - started) : elapsed)
        var lines = ["Optional real-workflow timing session · format 1", "Session: \(active ? "running (snapshot only)" : "stopped")", "Observed duration, seconds: \(Int(duration.rounded()))", "Real operations only; no synthetic workloads or automatic reanalysis.", "Nested timings overlap; totals must not be added. Scheduling and cache effects are included.", "p95 uses at most 256 recent retained observations; mean/min/max cover the session.", "At most 100,000 completed observations per category are retained; omitted observations are counted explicitly.", "Recording adds overhead. UI scheduling delays are not GPU kernel timings. Unspecified outcomes have no success/failure classification.", "No event order, names, paths, IDs, image data, hardware identifiers or error text are recorded.", "", "operation | retained completed | omitted | known failures | unspecified outcomes | unfinished at snapshot/stop | mean ms | min ms | max ms | recent p95 ms"]
        for operation in LocalOperation.allCases {
            guard let m = metrics[operation], m.count > 0 else {
                lines.append("\(operation.rawValue) | not completed | unfinished: \(metrics[operation]?.pending ?? 0)"); continue
            }
            let sorted = m.recent.sorted(), index = Swift.max(0, Int(ceil(Double(m.recent.count) * 0.95)) - 1)
            let values = [m.total / Double(m.count), m.min, m.max, sorted[index]].map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: " | ")
            lines.append("\(operation.rawValue) | \(m.count) | \(m.dropped) | \(m.failures) | \(m.unspecified) | \(m.pending) | \(values)")
        }
        let ranked = metrics.filter { $0.key != .eventLoop && $0.value.count > 0 }.sorted { $0.value.total / Double($0.value.count) > $1.value.total / Double($1.value.count) }.prefix(3)
        lines.append("\nHighest observed mean latency (overlapping categories, not a causal diagnosis):")
        if ranked.isEmpty { lines.append("No completed real operations were observed.") }
        for (operation, metric) in ranked { lines.append("\(operation.rawValue): \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), metric.total / Double(metric.count))) ms mean across \(metric.count) operations") }
        lines.append("\nUnobserved work is not a zero-time measurement. A crash loses unsaved timings. Performance does not establish segmentation accuracy.")
        return lines.joined(separator: "\n")
    }
}

@MainActor final class LocalPerformanceSession: ObservableObject {
    static let shared = LocalPerformanceSession()
    @Published private(set) var active = false
    private var heartbeat: Timer?
    private var token = 0
    func start(minutes: Int = 30) {
        stop(); LocalPerformanceRecorder.shared.start(minutes: minutes); active = true
        let generation = token
        var previous = ProcessInfo.processInfo.systemUptime
        var wasForeground = NSApplication.shared.isActive
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.token == generation else { return }
                let current = ProcessInfo.processInfo.systemUptime
                if NSApplication.shared.isActive && wasForeground {
                    // The timer span records actual main-loop scheduling delay.
                    let span = LocalPerformanceRecorder.shared.begin(.eventLoop, elapsedMilliseconds: Swift.max(0, (current - previous - 0.25) * 1000))
                    span?.finish(success: true)
                }
                wasForeground = NSApplication.shared.isActive
                previous = current
                if !LocalPerformanceRecorder.shared.isActive { self.stop() }
            }
        }
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { token += 1; LocalPerformanceRecorder.shared.stop(); heartbeat?.invalidate(); heartbeat = nil; active = false }
    func clear() { stop(); LocalPerformanceRecorder.shared.clear() }
}

nonisolated enum LocalTiming {
    static func measure<T>(_ operation: LocalOperation, _ work: () throws -> T) rethrows -> T {
        let span = LocalPerformanceRecorder.shared.begin(operation)
        do { let result = try work(); span?.finish(success: true); return result }
        catch { span?.finish(success: false); throw error }
    }
}
