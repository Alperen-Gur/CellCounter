import SwiftUI

/// The measured region can be smaller than the display grid after registration
/// or filtering. Surface that scientific boundary beside the measurements.
struct WorkbenchSupportNote: View {
    let support: WorkbenchJSON
    var volume = false

    private var excluded: Int { support["invalidPixelCount"].integer ?? 0 }
    private var clipped: Int {
        volume ? support["clippedVoxelCount"].integer ?? 0 : support["clippedPixelCount"].integer ?? 0
    }
    private var removed: Int { support["removedLabelCount"].integer ?? 0 }

    var body: some View {
        if support["present"].bool == true || clipped > 0 {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(support["validPixelCount"].integer ?? 0) valid \(volume ? "voxels" : "pixels") · \(excluded) filled or unsupported samples excluded")
                if let physical = support[volume ? "volumeUm3" : "areaUm2"].number {
                    Text("Valid \(volume ? "volume" : "area"): \(physical, specifier: "%.3f") \(volume ? "µm³" : "µm²")")
                }
                if clipped > 0 {
                    Text("\(clipped) unsupported labeled samples clipped · \(support["affectedLabelCount"].integer ?? 0) objects affected\(removed > 0 ? " · \(removed) removed" : "")")
                }
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
