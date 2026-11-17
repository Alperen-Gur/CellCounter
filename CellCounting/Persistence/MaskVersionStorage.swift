import Foundation

/// The "Mask versions kept per image" setting.
nonisolated enum MaskVersionRetention {
    static let defaultsKey = "cc-mask-versions-kept"
    static let defaultLimit = 5
    /// Choices offered in Settings. 0 keeps every saved version.
    static let choices = [3, 5, 10, 0]

    /// The stored choice, or the default when none was made.
    static func limit(in defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultLimit }
        let value = defaults.integer(forKey: defaultsKey)
        return value >= 0 ? value : defaultLimit
    }

    static func label(for limit: Int) -> String {
        limit <= 0 ? "Keep all" : "\(limit)"
    }
}

/// Value copy of a saved mask version for lists and sheets. Views hold this
/// rather than the model object, so a version that is removed (used, capped
/// or deleted) is never read after its row is gone.
nonisolated struct SegmentationVariantSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let imageId: UUID
    let detectorId: String
    let label: String
    let createdAt: Date
    let cellCount: Int
    /// -1 while the mean confidence has not been computed yet.
    let meanConfidence: Double

    var isMeanConfidencePending: Bool { meanConfidence < 0 }
}

extension SegmentationVariantSummary {
    @MainActor init(_ record: SegmentationVariantRecord) {
        self.init(id: record.id, imageId: record.imageId, detectorId: record.detectorId,
                  label: record.label, createdAt: record.createdAt, cellCount: record.cellCount,
                  meanConfidence: record.meanConfidence)
    }
}

/// Off-main part of the saved mask version upkeep: one stored blob in, its
/// compressed form, content hash and (when asked) mean confidence out.
nonisolated enum MaskVersionCompaction {
    struct Input: Sendable {
        let id: UUID
        let stored: Data
        let needsMeanConfidence: Bool
    }

    struct Output: Sendable {
        let id: UUID
        let stored: Data
        let storageFormat: Int
        let contentHash: String
        /// Nil when it was not requested.
        let meanConfidence: Double?
    }

    /// Nil when the blob cannot be read (or, if the mean is needed, decoded);
    /// such a row is left exactly as it is. The compressed result is checked
    /// by decompressing it again: it must reproduce the plain JSON byte for
    /// byte, so the decoded cells are identical before and after.
    static func process(_ input: Input) -> Output? {
        autoreleasepool {
            guard let plain = try? CellsBlobCodec.plainJSON(input.stored) else { return nil }
            var mean: Double?
            if input.needsMeanConfidence {
                guard let cells = try? DetectionRecord.decodeCellsDataForReview(plain) else { return nil }
                mean = SegmentationVariantRecord.meanConfidence(of: cells)
            }
            let stored = CellsBlobCodec.isCompressed(input.stored)
                ? input.stored
                : CellsBlobCodec.compress(plain)
            guard (try? CellsBlobCodec.plainJSON(stored)) == plain else { return nil }
            return Output(id: input.id, stored: stored,
                          storageFormat: CellsBlobCodec.storageFormat(of: stored),
                          contentHash: CellsBlobCodec.sha256Hex(plain),
                          meanConfidence: mean)
        }
    }
}
