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

    static let samples: [RecentBatch] = [
        .init(id: "r1", name: "Patient-OM-04, passage 3, ROCK-i",         count: 1247, when: "2 hours ago",     seed: 17),
        .init(id: "r2", name: "Plate B12 — control vs Y-27632",           count: 891,  when: "Yesterday, 16:42", seed: 33),
        .init(id: "r3", name: "Keratinocyte enrichment screen, day 7",    count: 2106, when: "May 24",          seed: 51),
        .init(id: "r4", name: "Fibroblast morphology, donor 12",          count: 643,  when: "May 22",          seed: 7),
        .init(id: "r5", name: "Stem-like population validation",          count: 1518, when: "May 20",          seed: 89),
    ]
}
