import SwiftUI

/// Procedural microscope-image renderer with optional cell overlay.
/// Mirrors `CellSampleImage` from the JSX prototype.
enum OverlayMode { case bbox, outline }

struct CellSampleImage: View {
    let cells: [DetectedCell]
    var seed: Int = 42
    var showOverlay: Bool = true
    var overlayMode: OverlayMode = .bbox
    var thresholds: [Double] = [20, 30]
    /// Renders only cells with confidence below this threshold as dashed (uncertainty viz).
    var uncertaintyThreshold: Double = 0.55

    var body: some View {
        Canvas { context, size in
            // Vignette background
            let bg = Gradient(colors: [
                Color(OKLCH(0.78, 0.005, 60)),
                Color(OKLCH(0.62, 0.005, 60)),
            ])
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(bg,
                                      center: CGPoint(x: size.width/2, y: size.height/2),
                                      startRadius: 0,
                                      endRadius: max(size.width, size.height) * 0.65)
            )

            // grain
            var grainRng = SeededRNG(seed &* 19)
            let step: CGFloat = 6
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    let dx = CGFloat(grainRng.next()) * step
                    let dy = CGFloat(grainRng.next()) * step
                    context.fill(
                        Path(ellipseIn: CGRect(x: x+dx, y: y+dy, width: 0.6, height: 0.6)),
                        with: .color(.black.opacity(0.05))
                    )
                    x += step
                }
                y += step
            }

            // cell bodies
            var rng = SeededRNG(seed &* 17)
            for c in cells {
                let tone = 0.32 + rng.next() * 0.18
                let rim  = 0.62 + rng.next() * 0.10
                let r = c.diameterPx/2 - 1.5
                let body = Path(ellipseIn: CGRect(x: c.cx - r, y: c.cy - r, width: r*2, height: r*2))
                context.fill(body, with: .color(Color(OKLCH(tone, 0.01, 60)).opacity(0.55)))
                context.stroke(body, with: .color(Color(OKLCH(rim, 0.01, 60)).opacity(0.7)), lineWidth: 0.8)
                // nucleus
                let nx = c.cx + (rng.next() - 0.5) * 3
                let ny = c.cy + (rng.next() - 0.5) * 3
                let rx = c.diameterPx * 0.18
                let ry = c.diameterPx * 0.13
                let nuc = Path(ellipseIn: CGRect(x: nx - rx, y: ny - ry, width: rx*2, height: ry*2))
                context.fill(nuc, with: .color(Color(OKLCH(tone - 0.08, 0.01, 60)).opacity(0.6)))
            }

            // overlay
            if showOverlay {
                for c in cells {
                    let idx = BinMath.binIndex(for: c.diameter, thresholds: thresholds)
                    let col = Tokens.binColor(idx)
                    let isUncertain = c.confidence < uncertaintyThreshold
                    let r = c.diameterPx / 2
                    let rect = CGRect(x: c.cx - r, y: c.cy - r, width: c.diameterPx, height: c.diameterPx)
                    let path = overlayMode == .outline
                        ? Path(ellipseIn: rect)
                        : Path(roundedRect: rect, cornerRadius: 2)
                    context.fill(path, with: .color(col.opacity(overlayMode == .outline ? 0.18 : 0.10)))
                    let style: StrokeStyle = isUncertain
                        ? StrokeStyle(lineWidth: 1.5, dash: [3.5, 3])
                        : StrokeStyle(lineWidth: 1.5)
                    context.stroke(path, with: .color(col), style: style)
                }
            }
        }
    }
}

/// Smaller stylized thumbnail (for "Recent" rows + batch strip).
struct ThumbDots: View {
    let seed: Int
    var body: some View {
        Canvas { context, size in
            // background gradient
            let bg = Gradient(colors: [
                Color(OKLCH(0.93, 0.01, 60)),
                Color(OKLCH(0.84, 0.01, 60)),
            ])
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(bg,
                                      center: CGPoint(x: size.width/2, y: size.height/2),
                                      startRadius: 0,
                                      endRadius: size.width/2)
            )
            var rng = SeededRNG(seed &* 13)
            for _ in 0..<18 {
                let x = CGFloat(rng.next()) * size.width
                let y = CGFloat(rng.next()) * size.height
                let r = CGFloat(0.6 + rng.next() * 1.2)
                context.fill(
                    Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)),
                    with: .color(Color(OKLCH(0.55, 0.02, 60)).opacity(0.5 + rng.next() * 0.3))
                )
            }
        }
    }
}

/// Tiny batch-strip thumbnail with deliberate blur — matches `.batch-thumb-sim`.
struct BatchThumbSim: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Tokens.bgSunken))
            let positions: [(CGFloat, CGFloat)] = [(0.2, 0.3), (0.8, 0.4), (0.3, 0.7), (0.7, 0.75), (0.5, 0.5)]
            for (fx, fy) in positions {
                let r: CGFloat = 1.5
                context.fill(
                    Path(ellipseIn: CGRect(x: fx*size.width - r, y: fy*size.height - r, width: r*2, height: r*2)),
                    with: .color(Color(OKLCH(0.55, 0.06, 60)).opacity(0.55))
                )
            }
        }
        .blur(radius: 0.3)
    }
}
