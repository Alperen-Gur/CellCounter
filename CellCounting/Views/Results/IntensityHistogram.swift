import SwiftUI
import CoreGraphics

// MARK: — Main view

struct IntensityHistogram: View {
    let image: ImageRecord
    @Environment(AppTheme.self) private var theme

    @State private var data: IntensityHistogramData = .empty
    /// The file `data` was computed from.
    @State private var computedFor: URL? = nil

    private let chartH: CGFloat = 80
    private let chartW: CGFloat = 256   // one point per bucket when fully wide

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Bar chart
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Tokens.bgSunken))
                    let maxBucket = data.buckets.max() ?? 1
                    guard maxBucket > 0 else { return }
                    let barW = size.width / 256
                    for i in 0..<256 {
                        let h = CGFloat(data.buckets[i]) / CGFloat(maxBucket) * size.height
                        let rect = CGRect(x: CGFloat(i) * barW,
                                          y: size.height - h,
                                          width: max(barW, 1),
                                          height: h)
                        ctx.fill(Path(rect), with: .color(Tokens.text.opacity(0.6)))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: chartH)
                .cornerRadius(Tokens.Radius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )

                // Stats overlay
                if data.maxVal > 0 {
                    Text(String(format: "min: %d · max: %d · mean: %.1f · σ: %.1f",
                                data.minVal, data.maxVal, data.mean, data.sigma))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Tokens.bgOverlay)
                        .cornerRadius(3)
                        .padding(5)
                }
            }

            // X-axis labels
            HStack {
                Text("0")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Text("128")
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
                Text("255")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Tokens.textTertiary)
        }
        // Cancelled when the image changes or the panel goes away; only the
        // file URL (a value) leaves the main actor.
        .task(id: source) { await load(source) }
    }

    /// The decodable file behind `image`, or nil when it isn't a format
    /// `ImageLoader.load` decodes (the histogram then stays empty, as before).
    private var source: URL? {
        let url = ImageLoader.displayDecodableURL(for: image.displayURL)
        return ImageLoader.nativeSupported.contains(url.pathExtension.lowercased()) ? url : nil
    }

    private func load(_ url: URL?) async {
        guard let url else {
            data = .empty
            computedFor = nil
            return
        }
        guard computedFor != url else { return }
        guard let result = await ResultsPixelSampler.shared.histogram(at: url),
              !Task.isCancelled else { return }
        data = result
        computedFor = url
    }
}
