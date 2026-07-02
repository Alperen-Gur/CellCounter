import Foundation

/// Cellpose channel selection for multi-channel fluorescence images.
///
/// Maps to Cellpose's `channels=[cyto, nuclei]` argument:
///   - 0 = grayscale / none
///   - 1 = red channel
///   - 2 = green channel
///   - 3 = blue channel
struct DetectionChannels: Codable, Equatable {
    /// Channel index for cytoplasm segmentation. 0 = grayscale.
    var cyto: Int
    /// Channel index for nuclei. 0 = none (no nuclear channel).
    var nuclei: Int

    // MARK: — Presets

    static let grayscale = DetectionChannels(cyto: 0, nuclei: 0)

    // MARK: — Helpers

    /// Channel indices as `[Int]` for `DetectionInput.channels`.
    var asArray: [Int] { [cyto, nuclei] }
}
