import Foundation

/// Matches two detectors' cells against each other by centroid proximity.
///
/// This is `AnnotationMatcher.evaluate`'s algorithm — build every candidate
/// pair inside a diameter-scaled radius, sort by distance, then walk the list
/// claiming each side at most once. That greedy nearest-neighbour pass is the
/// right one here for the same reason it is there: it is stable, it is
/// order-independent, and scaling the match window by each detection's own
/// diameter stops a large cell from stealing a small neighbour's partner.
///
/// It is a separate entry point rather than a call into `AnnotationMatcher`
/// because that API is typed against `GroundTruthAnnotation` — a SwiftData
/// `@Model`. Manufacturing throwaway `@Model` instances just to reuse the
/// function would insert rows into the user's store as a side effect of a
/// detection run. Same algorithm, no persistence hazard.
enum EnsembleMatcher {

    struct Pair {
        let a: DetectedCell
        let b: DetectedCell
        let distancePx: Double
    }

    struct Result {
        /// Cells both detectors found — they agree.
        let agreed: [Pair]
        /// Cells only the primary detector found.
        let onlyA: [DetectedCell]
        /// Cells only the secondary detector found.
        let onlyB: [DetectedCell]

        var agreementCount: Int { agreed.count }
        var disagreementCount: Int { onlyA.count + onlyB.count }
        var totalCount: Int { agreementCount + disagreementCount }

        /// Fraction of all distinct objects the two models agreed on, or nil
        /// when neither found anything (so callers can render "—" not 0/0).
        var agreementFraction: Double? {
            guard totalCount > 0 else { return nil }
            return Double(agreementCount) / Double(totalCount)
        }
    }

    /// - Parameter matchRadiusFactor: multiplier on a detection's diameter used
    ///   as the match window. 1.0 means "centroids within one diameter of each
    ///   other are the same cell", matching `AnnotationMatcher`'s default.
    static func match(a: [DetectedCell],
                      b: [DetectedCell],
                      matchRadiusFactor: Double = 1.0) -> Result {
        if a.isEmpty { return Result(agreed: [], onlyA: [], onlyB: b) }
        if b.isEmpty { return Result(agreed: [], onlyA: a, onlyB: []) }

        struct Candidate {
            let ai: Int
            let bi: Int
            let distance: Double
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(min(a.count * b.count, 1 << 16))
        for (ai, ca) in a.enumerated() {
            for (bi, cb) in b.enumerated() {
                let dx = ca.cx - cb.cx
                let dy = ca.cy - cb.cy
                let dist = (dx * dx + dy * dy).squareRoot()
                // Use the LARGER of the two diameters: if one model split a
                // cell the other kept whole, we still want the pair considered
                // so it reads as agreement-with-different-segmentation rather
                // than two separate disagreements.
                let radius = matchRadiusFactor * max(max(ca.diameterPx, cb.diameterPx), 1)
                if dist <= radius {
                    candidates.append(Candidate(ai: ai, bi: bi, distance: dist))
                }
            }
        }
        candidates.sort { $0.distance < $1.distance }

        var claimedA = Set<Int>()
        var claimedB = Set<Int>()
        var pairs: [Pair] = []
        pairs.reserveCapacity(min(a.count, b.count))
        for c in candidates {
            if claimedA.contains(c.ai) || claimedB.contains(c.bi) { continue }
            claimedA.insert(c.ai)
            claimedB.insert(c.bi)
            pairs.append(Pair(a: a[c.ai], b: b[c.bi], distancePx: c.distance))
        }

        let onlyA = a.enumerated().filter { !claimedA.contains($0.offset) }.map(\.element)
        let onlyB = b.enumerated().filter { !claimedB.contains($0.offset) }.map(\.element)
        return Result(agreed: pairs, onlyA: onlyA, onlyB: onlyB)
    }
}

/// "Second opinion": runs two detectors on the same image, matches their
/// masks, and flags only the cells they DISAGREE about.
///
/// The point is triage. A confluent field gives you 400 cells to check; two
/// independent models will agree on ~390 of them, and the 12 they don't agree
/// on are exactly the ones worth a human's attention. This turns "review 400
/// cells" into "review the 12 that matter".
///
/// ### How a disagreement gets surfaced
///
/// There is no per-cell "needs review" field to set, so we use the confidence
/// channel the whole app already routes on. Three numbers matter:
///
///   * `0.50` — the default confidence slider. Cells below it are hidden from
///     the overlay, counts, bins, and exports.
///   * `0.65` — `AppState.reviewQueueConfidenceCutoff`. Uncorrected cells
///     below it populate the Review queue.
///   * so the window `(0.50, 0.65)` means **visible and counted, but queued
///     for review** — precisely the semantics a flagged cell needs.
///
/// Disagreements are therefore emitted at `disagreementConfidence` (0.60,
/// inside that window) and agreements are floored at `agreementFloor` (0.80,
/// clear of it). Raising the confidence slider above 0.60 will hide the
/// flagged cells, which is a coherent thing for it to do — that is what the
/// slider means — but it does make the flags invisible, so the counts are also
/// reported in `image_stats` where the slider can't reach them.
///
/// ### Reported stats
/// `ensemble_agreement`, `ensemble_disagreement`, `ensemble_only_a`,
/// `ensemble_only_b`, `ensemble_agreement_pct`.
struct EnsembleDetectionService: DetectionService {
    let primary: DetectionService
    let secondary: DetectionService
    let primaryModelId: String
    let secondaryModelId: String

    /// Inside the (0.50 visible, 0.65 review) window — see the type doc.
    static let disagreementConfidence: Double = 0.60
    /// Clear of the review cutoff, so agreed cells don't flood the queue.
    static let agreementFloor: Double = 0.80

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        // Each member gets an input naming ITS own model id — the member
        // services resolve their catalog id from `input.modelId`, and handing
        // both the ensemble's id would make them fail to resolve.
        let inputA = Self.rewrite(input, modelId: primaryModelId)
        let inputB = Self.rewrite(input, modelId: secondaryModelId)

        // Run both. They are separate subprocesses, so let them overlap.
        async let resultA = primary.detect(inputA)
        async let resultB = secondary.detect(inputB)

        let a: DetectionResult
        let b: DetectionResult
        do {
            a = try await resultA
            b = try await resultB
        } catch let error as DetectionError {
            // A cancel is a cancel — don't dress it up as an ensemble failure.
            if case .cancelled = error { throw error }
            throw error
        }

        let match = EnsembleMatcher.match(a: a.cells, b: b.cells)

        var cells: [DetectedCell] = []
        cells.reserveCapacity(match.totalCount)

        // Agreed cells: keep the primary's geometry (it owns the contours the
        // overlay draws) and lift confidence clear of the review cutoff, using
        // the mean of the two models' own confidences as the base so a pair
        // both models were unsure about still ranks below a pair both were
        // certain of.
        for pair in match.agreed {
            var cell = pair.a
            let mean = (pair.a.confidence + pair.b.confidence) / 2
            cell.confidence = min(1.0, max(Self.agreementFloor, mean))
            cells.append(cell)
        }
        // Disagreements — the whole point of the feature.
        for var cell in match.onlyA {
            cell.confidence = Self.disagreementConfidence
            cells.append(cell)
        }
        for var cell in match.onlyB {
            // Cells the PRIMARY missed. Including them is the half of the
            // second opinion that actually finds new objects rather than just
            // doubting existing ones.
            cell.confidence = Self.disagreementConfidence
            cells.append(cell)
        }

        var stats = a.imageStats ?? [:]
        stats["ensemble_agreement"] = Double(match.agreementCount)
        stats["ensemble_disagreement"] = Double(match.disagreementCount)
        stats["ensemble_only_a"] = Double(match.onlyA.count)
        stats["ensemble_only_b"] = Double(match.onlyB.count)
        if let fraction = match.agreementFraction {
            stats["ensemble_agreement_pct"] = fraction * 100
        }

        NotificationCenter.default.post(
            name: .ccDetectionStage, object: nil,
            userInfo: ["line": "ensemble: \(match.agreementCount) agreed, "
                             + "\(match.disagreementCount) to review "
                             + "(\(match.onlyA.count) only \(primaryModelId), "
                             + "\(match.onlyB.count) only \(secondaryModelId))"])

        return DetectionResult(cells: cells,
                               imageWidth: a.imageWidth,
                               imageHeight: a.imageHeight,
                               imageStats: stats)
    }

    /// Copy a `DetectionInput` with a different model id. `DetectionInput` has
    /// no `with(...)`, and it is owned by another lane, so we rebuild it.
    private static func rewrite(_ input: DetectionInput, modelId: String) -> DetectionInput {
        DetectionInput(imageURL: input.imageURL,
                       modelId: modelId,
                       pxPerUm: input.pxPerUm,
                       confidenceThreshold: input.confidenceThreshold,
                       channels: input.channels,
                       backgroundSubtract: input.backgroundSubtract,
                       rollingBallRadius: input.rollingBallRadius,
                       watershedSplit: input.watershedSplit,
                       watershedMinDistance: input.watershedMinDistance,
                       smallThreshold: input.smallThreshold,
                       largeThreshold: input.largeThreshold,
                       useGPU: input.useGPU)
    }
}

// MARK: — Downloader

/// `ModelDownloader` for the Ensemble family.
///
/// Owns no artefacts of its own — it composes two other models. "Installed"
/// means both members are installed, and `install()` forwards to whichever
/// member is missing rather than pretending there is an ensemble to download.
struct EnsembleDownloader: ModelDownloader {
    let family: ModelFamily = .ensemble

    static let modelId = "ensemble-2"
    static let primaryKey = "cc-ensemble-primary"
    static let secondaryKey = "cc-ensemble-secondary"

    /// Cached "are both members installed?" verdict.
    ///
    /// `isInstalled` is a nonisolated protocol requirement that runs during
    /// view body evaluation, so it cannot reach the `@MainActor` registry and
    /// must not block. Same solution the Cellpose-SAM downloader uses for its
    /// import probe: the async `probeInstalled` does the real work on the main
    /// actor and writes the answer here; `isInstalled` only reads it.
    static let membersReadyCacheKey = "cc-ensemble-members-ready"

    /// Defaults pair the recommended Cellpose model with the classical
    /// detector — which needs no download, so a fresh install has a working
    /// ensemble the moment Cellpose is installed.
    static let defaultPrimary = "cp-cyto3"
    static let defaultSecondary = ModelCatalog.classicalFallbackId

    static func primaryId() -> String {
        UserDefaults.standard.string(forKey: primaryKey) ?? defaultPrimary
    }

    static func secondaryId() -> String {
        UserDefaults.standard.string(forKey: secondaryKey) ?? defaultSecondary
    }

    /// Persist a member pair. Rejects an ensemble id on either side (an
    /// ensemble of ensembles would recurse) and rejects a pair of the same
    /// model (which would agree with itself on everything and flag nothing).
    @discardableResult
    static func setMembers(primary: String, secondary: String) -> Bool {
        guard primary != secondary,
              primary != modelId, secondary != modelId else { return false }
        UserDefaults.standard.set(primary, forKey: primaryKey)
        UserDefaults.standard.set(secondary, forKey: secondaryKey)
        // The cached verdict describes the OLD pair, so it's meaningless now.
        // Clearing it makes the row read "Checking…" until the re-probe lands,
        // rather than claiming the new pair is ready on the old pair's word.
        UserDefaults.standard.removeObject(forKey: membersReadyCacheKey)
        return true
    }

    /// Model ids that may serve as an ensemble member.
    static func eligibleMembers(from models: [DetectionModelInfo]) -> [DetectionModelInfo] {
        models.filter { $0.family != .ensemble && $0.family != .all && !$0.comingSoon }
    }

    // MARK: — ModelDownloader

    /// Cheap and main-safe: reads the cached verdict only. Never touches the
    /// registry (which is `@MainActor`) and never forks a process.
    func isInstalled(modelId: String) -> Bool {
        guard modelId == Self.modelId else { return false }
        return (UserDefaults.standard.object(forKey: Self.membersReadyCacheKey) as? Bool) ?? false
    }

    func probeInstalled(modelId: String) async -> Bool {
        guard modelId == Self.modelId else { return false }
        let primary = Self.primaryId()
        let secondary = Self.secondaryId()
        // A pair that is identical, or that names the ensemble itself, can
        // never produce a meaningful second opinion.
        guard primary != secondary,
              primary != Self.modelId, secondary != Self.modelId else {
            UserDefaults.standard.set(false, forKey: Self.membersReadyCacheKey)
            return false
        }
        // Probed sequentially rather than concurrently: the registry is a
        // non-Sendable `@MainActor` type, so racing two `async let`s over it
        // would need it captured across actors. Each member probe is cached by
        // its own family anyway, so the serial cost is negligible.
        // Written out rather than `a && b`: `&&` takes its right operand as an
        // autoclosure, which can't contain an `await`.
        let primaryReady = await Self.probeMember(primary)
        let secondaryReady = await Self.probeMember(secondary)
        let ready = primaryReady && secondaryReady
        UserDefaults.standard.set(ready, forKey: Self.membersReadyCacheKey)
        return ready
    }

    /// Deep-probe one member through the registry, hopping to the main actor
    /// to read it. The registry then routes to that family's own off-main probe.
    private static func probeMember(_ memberId: String) async -> Bool {
        guard let registry = await MainActor.run(body: { DetectorRegistry.current }) else {
            return false
        }
        return await registry.probeInstalled(memberId, models: ModelCatalog.all)
    }

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        guard modelId == Self.modelId else {
            throw NSError(domain: "EnsembleDownloader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unknown ensemble id: \(modelId)",
            ])
        }
        let primary = Self.primaryId()
        let secondary = Self.secondaryId()
        await MainActor.run {
            progress.stage = .checkingDependencies
            progress.append("[ensemble] members: \(primary) + \(secondary)")
        }

        guard primary != secondary else {
            throw NSError(domain: "EnsembleDownloader", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "The second opinion needs two DIFFERENT models — a model agrees with "
                  + "itself on everything. Pick a pair in Models → Add model.",
            ])
        }

        let models = ModelCatalog.all
        var missing: [String] = []
        for member in [primary, secondary] {
            let ok = await Self.probeMember(member)
            if !ok { missing.append(member) }
        }
        if !missing.isEmpty {
            let names = missing.map { id in
                models.first(where: { $0.id == id })?.name ?? id
            }.joined(separator: " and ")
            UserDefaults.standard.set(false, forKey: Self.membersReadyCacheKey)
            throw NSError(domain: "EnsembleDownloader", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "The ensemble needs both of its models installed. Install \(names) first, "
                  + "or pick a different pair in Models.",
            ])
        }
        UserDefaults.standard.set(true, forKey: Self.membersReadyCacheKey)
        await MainActor.run {
            progress.append("[ensemble] both members installed — ready")
            progress.stage = .ready
        }
    }

    @MainActor
    func uninstall(modelId: String) throws {
        // Composes other models; owns nothing to remove. Leave the member
        // selection persisted so the pairing survives a toggle.
    }

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 {
        // Reporting the members' bytes here would double-count them against
        // their own rows in the Models list.
        0
    }

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        guard modelId == Self.modelId,
              let registry = DetectorRegistry.current else { return nil }
        let models = ModelCatalog.all
        let primaryId = Self.primaryId()
        let secondaryId = Self.secondaryId()
        guard primaryId != secondaryId,
              primaryId != Self.modelId, secondaryId != Self.modelId else { return nil }
        guard let a = registry.detector(for: primaryId, models: models),
              let b = registry.detector(for: secondaryId, models: models) else {
            return nil
        }
        return EnsembleDetectionService(primary: a,
                                        secondary: b,
                                        primaryModelId: primaryId,
                                        secondaryModelId: secondaryId)
    }
}
