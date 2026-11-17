import CryptoKit
import Foundation

/// Stored form of a saved cell array (`[CellPayload]` JSON).
///
/// Detections (`StoredCellsRecord`) and saved mask versions
/// (`SegmentationVariantRecord`) are compressed: their bytes start with the
/// four-byte marker `CCZ1`, followed by an LZFSE stream of the same plain
/// JSON. Blobs written before compression existed are plain JSON and start
/// with `[`, so the first bytes alone tell the two forms apart and every
/// reader accepts both.
nonisolated enum CellsBlobCodec {
    /// `storageFormat` values of `SegmentationVariantRecord` and `StoredCellsRecord`.
    static let plainJSONFormat = 0
    static let compressedFormat = 1

    static let magic = Data("CCZ1".utf8)

    enum CodecError: Error, LocalizedError {
        case unreadableCompressedData

        var errorDescription: String? {
            "Saved cell data is marked as compressed but could not be decompressed."
        }
    }

    static func isCompressed(_ stored: Data) -> Bool {
        stored.count >= magic.count && stored.prefix(magic.count).elementsEqual(magic)
    }

    /// `storageFormat` value describing `stored`.
    static func storageFormat(of stored: Data) -> Int {
        isCompressed(stored) ? compressedFormat : plainJSONFormat
    }

    /// Marker followed by LZFSE. Input that is empty, already compressed or
    /// cannot be compressed is returned unchanged, so the result is always a
    /// valid stored form; `storageFormat(of:)` says which one it is.
    static func compress(_ json: Data) -> Data {
        guard !json.isEmpty, !isCompressed(json) else { return json }
        guard let packed = try? (json as NSData).compressed(using: .lzfse) else { return json }
        var stored = Data(capacity: magic.count + packed.length)
        stored.append(magic)
        stored.append(packed as Data)
        return stored
    }

    /// The plain JSON of a stored blob: decompressed when it carries the
    /// marker, otherwise the input itself.
    static func plainJSON(_ stored: Data) throws -> Data {
        guard isCompressed(stored) else { return stored }
        let payload = Data(stored.dropFirst(magic.count))
        do {
            return try (payload as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw CodecError.unreadableCompressedData
        }
    }

    /// Lowercase hex SHA-256, used as `SegmentationVariantRecord.contentHash`
    /// (always computed over the plain JSON, never over compressed bytes).
    static func sha256Hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(SHA256.byteCount * 2)
        for byte in SHA256.hash(data: data) {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
