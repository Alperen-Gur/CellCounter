import SwiftUI
import CoreGraphics

// MARK: — Profile mode enum

enum ProfileMode { case idle, drawing }

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
    @State private var profile: [LineProfileSample] = []
    /// The line being sampled, in source pixels. Its `.task(id:)` is
    /// cancelled when the line is reset or replaced, or the tool closes.
    @State private var request: LineProfileRequest? = nil

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
        .task(id: request) {
            guard let request else { return }
            guard let samples = await ResultsPixelSampler.shared.profile(
                    at: request.url, from: request.start, to: request.end, count: request.count),
                  !Task.isCancelled else { return }
            profile = samples
        }
        .onDisappear {
            // The tool keeps the image's grey plane only while it is open.
            if let url = Self.decodableURL(for: image) {
                Task { await ResultsPixelSampler.shared.releasePlane(for: url) }
            }
        }
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
        request = nil
    }

    // MARK: — Profile sampling

    private func computeProfile() {
        guard let s = startPt, let e = endPt else { return }
        // No decodable file: the profile stays empty, as before.
        guard let url = Self.decodableURL(for: image) else { return }
        // Only values leave the main actor; an unchanged line keeps its task.
        request = LineProfileRequest(url: url,
                                     start: viewToSource(s, scale: viewScale, offset: viewOffset),
                                     end: viewToSource(e, scale: viewScale, offset: viewOffset),
                                     count: sampleCount)
    }

    /// The file `ImageLoader.load` would decode for `image`, when supported.
    private static func decodableURL(for image: ImageRecord) -> URL? {
        let url = ImageLoader.displayDecodableURL(for: image.displayURL)
        return ImageLoader.nativeSupported.contains(url.pathExtension.lowercased()) ? url : nil
    }

    private func viewToSource(_ pt: CGPoint, scale: Double, offset: CGPoint) -> CGPoint {
        CGPoint(
            x: (pt.x - offset.x) / scale,
            y: (pt.y - offset.y) / scale
        )
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

/// One requested line profile, in source pixels.
private struct LineProfileRequest: Equatable {
    let url: URL
    let start: CGPoint
    let end: CGPoint
    let count: Int
}

// MARK: — Profile plot (mini chart)

private struct ProfilePlot: View {
    let samples: [LineProfileSample]

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
