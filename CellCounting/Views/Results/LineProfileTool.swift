import SwiftUI
import CoreGraphics

// MARK: — Profile mode enum

enum ProfileMode { case idle, drawing }

// MARK: — Profile data

private struct ProfileSample {
    let position: Int   // 0..<256
    let intensity: Double
}

// MARK: — Main view

struct LineProfileTool: View {
    let image: ImageRecord
    /// On-screen view scale (view points = source pixels * viewScale).
    var viewScale: Double
    var viewOffset: CGPoint

    @Binding var mode: ProfileMode

    // State: two taps define the line in VIEW coordinates.
    @State private var startPt: CGPoint? = nil
    @State private var endPt: CGPoint? = nil
    @State private var profile: [ProfileSample] = []
    @State private var samplingForLine: (CGPoint, CGPoint)? = nil

    private let sampleCount = 256

    var body: some View {
        ZStack {
            // Invisible full-area tap catcher — only active when mode == .drawing.
            if mode == .drawing {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { pt in handleTap(pt) }
            }

            // Visual: dots and line
            Canvas { ctx, _ in
                guard mode == .drawing else { return }
                if let s = startPt {
                    drawDot(ctx: &ctx, at: s, isStart: true)
                }
                if let s = startPt, let e = endPt {
                    var linePath = Path()
                    linePath.move(to: s)
                    linePath.addLine(to: e)
                    ctx.stroke(linePath, with: .color(.white.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    drawDot(ctx: &ctx, at: e, isStart: false)
                }
            }
            .allowsHitTesting(false)

            // Profile plot — floats near the endpoint when available.
            if let end = endPt, !profile.isEmpty, mode == .drawing {
                ProfilePlot(samples: profile)
                    .frame(width: 280, height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                            .fill(Tokens.bgSunken.opacity(0.94))
                            .overlay(
                                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                                    .strokeBorder(Tokens.border, lineWidth: 0.5)
                            )
                    )
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .position(floatingPosition(near: end))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: mode) { if mode == .idle { reset() } }
    }

    // MARK: — Tap handler

    private func handleTap(_ viewPt: CGPoint) {
        if startPt == nil {
            startPt = viewPt
            endPt = nil
            profile = []
        } else if endPt == nil {
            endPt = viewPt
            computeProfile()
        } else {
            // Third tap: reset
            reset()
        }
    }

    private func reset() {
        startPt = nil
        endPt = nil
        profile = []
        samplingForLine = nil
    }

    // MARK: — Profile sampling

    private func computeProfile() {
        guard let s = startPt, let e = endPt else { return }
        // Avoid re-computing if nothing changed.
        if let prev = samplingForLine, prev.0 == s, prev.1 == e { return }
        samplingForLine = (s, e)

        let capturedImage = image
        let scale = viewScale
        let offset = viewOffset
        let n = sampleCount
        let startSrc = viewToSource(s, scale: scale, offset: offset)
        let endSrc = viewToSource(e, scale: scale, offset: offset)

        Task.detached(priority: .userInitiated) {
            let samples = Self.sample(image: capturedImage,
                                      from: startSrc, to: endSrc, count: n)
            await MainActor.run { self.profile = samples }
        }
    }

    private func viewToSource(_ pt: CGPoint, scale: Double, offset: CGPoint) -> CGPoint {
        CGPoint(
            x: (pt.x - offset.x) / scale,
            y: (pt.y - offset.y) / scale
        )
    }

    // MARK: — Off-actor sampling (bilinear interpolation in grayscale)

    private static func sample(image: ImageRecord,
                                from start: CGPoint,
                                to end: CGPoint,
                                count: Int) -> [ProfileSample] {
        guard count > 0,
              let loaded = ImageLoader.loadStored(image) else { return [] }
        let cg = loaded.cgImage
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return [] }

        // Render to a grayscale buffer for fast pixel access.
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var result: [ProfileSample] = []
        result.reserveCapacity(count)
        let dx = Double(end.x - start.x) / Double(count - 1)
        let dy = Double(end.y - start.y) / Double(count - 1)

        for i in 0..<count {
            let px = Double(start.x) + dx * Double(i)
            let py = Double(start.y) + dy * Double(i)
            let intensity = bilinear(pixels: pixels, width: w, height: h, x: px, y: py)
            result.append(ProfileSample(position: i, intensity: intensity))
        }
        return result
    }

    /// Bilinear interpolation. Returns 0 for out-of-bounds samples (clamp at border).
    private static func bilinear(pixels: [UInt8], width: Int, height: Int,
                                  x: Double, y: Double) -> Double {
        let x0 = max(0, min(width  - 1, Int(x)))
        let y0 = max(0, min(height - 1, Int(y)))
        let x1 = min(width  - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let p00 = Double(pixels[y0 * width + x0])
        let p10 = Double(pixels[y0 * width + x1])
        let p01 = Double(pixels[y1 * width + x0])
        let p11 = Double(pixels[y1 * width + x1])
        return p00 * (1 - fx) * (1 - fy)
             + p10 * fx       * (1 - fy)
             + p01 * (1 - fx) * fy
             + p11 * fx       * fy
    }

    // MARK: — Drawing helpers

    private func drawDot(ctx: inout GraphicsContext, at pt: CGPoint, isStart: Bool) {
        let r: CGFloat = 5
        let ring = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
        ctx.fill(ring, with: .color(.white))
        let accent = Path(ellipseIn: CGRect(x: pt.x - r - 1.5, y: pt.y - r - 1.5,
                                            width: (r + 1.5) * 2, height: (r + 1.5) * 2))
        ctx.stroke(accent, with: .color(Color.accentColor.opacity(0.85)), lineWidth: 1.5)
    }

    private func floatingPosition(near pt: CGPoint) -> CGPoint {
        // Prefer below-right; clamp naively (parent clips anyway).
        CGPoint(x: pt.x + 150, y: pt.y + 60)
    }
}

// MARK: — Profile plot (mini chart)

private struct ProfilePlot: View {
    let samples: [ProfileSample]

    private var minI: Double { samples.map(\.intensity).min() ?? 0 }
    private var maxI: Double { max(1, samples.map(\.intensity).max() ?? 255) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                guard samples.count > 1 else { return }
                let n = samples.count
                let range = maxI - minI
                let pts: [CGPoint] = samples.map { s in
                    CGPoint(
                        x: CGFloat(s.position) / CGFloat(n - 1) * size.width,
                        y: size.height - CGFloat((s.intensity - minI) / range) * size.height
                    )
                }
                var linePath = Path()
                linePath.move(to: pts[0])
                for p in pts.dropFirst() { linePath.addLine(to: p) }
                ctx.stroke(linePath, with: .color(Tokens.text.opacity(0.8)), lineWidth: 1.2)

                // Area fill
                var area = linePath
                area.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: pts.first!.x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(Tokens.text.opacity(0.08)))
            }
            .frame(height: 56)
            .padding(.horizontal, 8)
            .padding(.top, 6)

            HStack {
                Text("0")
                Spacer()
                Text("px along line")
                    .foregroundStyle(Tokens.textTertiary)
                Spacer()
                Text("\(samples.count - 1)")
            }
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(Tokens.textTertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }
}
