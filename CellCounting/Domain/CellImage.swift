import Foundation

struct CellImage: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var seed: Int            // for procedural rendering until a real image is loaded
    var width: Int
    var height: Int
    var cells: [DetectedCell] = []
    /// Optional file URL on disk (nil if synthesized).
    var url: URL? = nil
}

struct RecentBatch: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    let when: String
    let seed: Int

    // Synthetic placeholder labels only — deliberately generic so nothing here can be
    // mistaken for a real (de-identified) patient specimen. The live Recents list is
    // driven by real BatchRecord data, not this array.
    static let samples: [RecentBatch] = [
        .init(id: "r1", name: "Demo batch 1 — cyto3",           count: 1247, when: "2 hours ago",     seed: 17),
        .init(id: "r2", name: "Demo batch 2 — control vs treated", count: 891, when: "Yesterday, 16:42", seed: 33),
        .init(id: "r3", name: "Synthetic sample A, day 7",      count: 2106, when: "May 24",          seed: 51),
        .init(id: "r4", name: "Synthetic sample B",             count: 643,  when: "May 22",          seed: 7),
        .init(id: "r5", name: "Example population screen",      count: 1518, when: "May 20",          seed: 89),
    ]
}
