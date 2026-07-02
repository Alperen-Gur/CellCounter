import SwiftUI
import CoreGraphics

// MARK: — Histogram data model

private struct HistogramData {
    let buckets: [Int]       // 256 entries
    let minVal: Int
    let maxVal: Int
    let mean: Double
    let sigma: Double

    static let empty = HistogramData(buckets: Array(repeating: 0, count: 256),
                                     minVal: 0, maxVal: 0, mean: 0, sigma: 0)
}

// MARK: — Main view

struct IntensityHistogram: View {
    let image: ImageRecord
    @Environment(AppTheme.self) private var theme

    @State private var data: HistogramData = .empty
    @State private var computedForId: UUID? = nil

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
        .onAppear { recomputeIfNeeded() }
        .onChange(of: image.id) { recomputeIfNeeded() }
    }

    private func recomputeIfNeeded() {
        guard computedForId != image.id else { return }
        let capturedImage = image
        Task.detached(priority: .userInitiated) {
            let result = Self.compute(for: capturedImage)
            await MainActor.run {
                self.data = result
                self.computedForId = capturedImage.id
            }
        }
    }

    // Off-main-actor; returns empty on failure (no fatalError, no force-unwrap).
    private static func compute(for record: ImageRecord) -> HistogramData {
        guard let loaded = ImageLoader.loadStored(record) else { return .empty }
        let src = loaded.cgImage

        // Downsample to 512×512 for speed
        let maxDim = 512
        let srcW = src.width, srcH = src.height
        let scale = min(1.0, Double(maxDim) / Double(max(srcW, srcH)))
        let dstW = max(1, Int(Double(srcW) * scale))
        let dstH = max(1, Int(Double(srcH) * scale))

        let space = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: dstW * dstH)
        guard let ctx = CGContext(data: &pixels,
                                  width: dstW, height: dstH,
                                  bitsPerComponent: 8, bytesPerRow: dstW,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return .empty
        }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

        var buckets = Array(repeating: 0, count: 256)
        var sum: Double = 0
        var minV = 255, maxV = 0
        for v in pixels {
            buckets[Int(v)] += 1
            sum += Double(v)
            if Int(v) < minV { minV = Int(v) }
            if Int(v) > maxV { maxV = Int(v) }
        }
        let n = Double(pixels.count)
        let mean = n > 0 ? sum / n : 0
        var variance: Double = 0
        for v in pixels { variance += (Double(v) - mean) * (Double(v) - mean) }
        let sigma = n > 1 ? sqrt(variance / n) : 0

        return HistogramData(buckets: buckets, minVal: minV, maxVal: maxV,
                             mean: mean, sigma: sigma)
    }
}
