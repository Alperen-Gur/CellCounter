import Foundation

/// Per-library note saying whether the review index was checked for stale rows:
/// rows whose image or detection no longer exists, whose image left its batch,
/// or whose detection is no longer the image's live one.
///
/// That check reads every review row, so it runs only while this note says it
/// is needed: the note is missing (a library this version has not checked yet),
/// it was written by an older version of the check, or stale rows were seen
/// since (`markNeedsCheck()`). Deletion, re-analysis and reset remove their
/// review rows in the same save, so they leave nothing to check.
///
/// The note is a small file next to the library's store, so every library, and
/// every copy of a library folder, carries its own state. Stores without a
/// folder (in-memory, including the fallback used when the disk store cannot
/// be opened) keep it in memory only and start out unchecked.
@MainActor
final class ReviewIndexCheck {
    /// Raise when the rules for a stale row change, so every library is
    /// checked once more under the new rules.
    static let repairVersion = 1
    static let fileName = "review-index-check.json"

    private struct Note: Codable {
        var repairVersion: Int
    }

    /// Nil for in-memory stores.
    let fileURL: URL?
    private var verifiedInMemory: Bool
    /// Advanced by every `markNeedsCheck()`. A check that started before
    /// stale rows were reported must not record the library as clean.
    private(set) var generation = 0

    init(fileURL: URL?, verified: Bool = false) {
        self.fileURL = fileURL
        self.verifiedInMemory = verified
    }

    /// The note for the store at `storeURL`, kept in the store's folder (the
    /// library root). In-memory stores report `/dev/null`.
    convenience init(storeURL: URL?) {
        guard let storeURL, storeURL.isFileURL, storeURL.path != "/dev/null" else {
            self.init(fileURL: nil)
            return
        }
        self.init(fileURL: storeURL.deletingLastPathComponent()
            .appendingPathComponent(Self.fileName, isDirectory: false))
    }

    /// True until a complete check has run for this library under the current rules.
    var needsCheck: Bool {
        guard let fileURL else { return !verifiedInMemory }
        guard let data = try? Data(contentsOf: fileURL),
              let note = try? JSONDecoder().decode(Note.self, from: data) else { return true }
        return note.repairVersion != Self.repairVersion
    }

    /// Records that the review index may hold stale rows again.
    func markNeedsCheck() {
        generation &+= 1
        verifiedInMemory = false
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Records a complete check, unless stale rows were reported after it
    /// started (`generation` moved on). A note that cannot be written only
    /// means the check runs again next time.
    func markVerified(sinceGeneration startGeneration: Int) {
        guard startGeneration == generation else { return }
        verifiedInMemory = true
        guard let fileURL,
              let data = try? JSONEncoder().encode(Note(repairVersion: Self.repairVersion)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
