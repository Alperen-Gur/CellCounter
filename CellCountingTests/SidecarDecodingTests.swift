import Foundation
import Testing
@testable import CellCounting

@MainActor
struct SidecarDecodingTests {

    // MARK: — Decoding

    private static let cellID = "11111111-2222-3333-4444-555555555555"

    private static var successJSON: Data {
        Data("""
        {"width": 640, "height": 480,
         "image_stats": {"focus_score": 3.5},
         "cells": [
          {"id": "\(cellID)", "cx": 10.5, "cy": 20.25, "diameter_um": 12.0,
           "diameter_px": 24.0, "confidence": 0.9, "edge_touching": true,
           "size_class": "large",
           "contour_px": [[0, 0], [10, 0], [10, 10], [0]]},
          {"id": "not-a-uuid", "cx": 1, "cy": 2, "diameter_um": 3,
           "diameter_px": 4, "confidence": 0.5,
           "contour_px": [[0, 0], [1, 1]]}
         ]}
        """.utf8)
    }

    @Test func successPayloadDecodesAndMapsDefaults() throws {
        let r = try SidecarPayload.decodeSync(stdout: Self.successJSON, exitCode: 0)
        #expect(r.imageWidth == 640)
        #expect(r.imageHeight == 480)
        #expect(r.imageStats == ["focus_score": 3.5])
        #expect(r.cells.count == 2)
        let c0 = r.cells[0]
        #expect(c0.id == UUID(uuidString: Self.cellID))
        #expect(c0.cx == 10.5 && c0.cy == 20.25)
        #expect(c0.diameter == 12 && c0.diameterPx == 24)
        #expect(c0.edgeTouching)
        #expect(!c0.likelyClump && !c0.isManual)
        #expect(c0.sizeClass == "large")
        // The malformed [0] pair is skipped; three valid points remain.
        #expect(c0.contourPx?.count == 3)
        // Fewer than three points drops the contour; a bad id gets a fresh UUID.
        #expect(r.cells[1].contourPx == nil)
        #expect(r.cells[1].sizeClass == "")
    }

    @Test func asyncDecodeMatchesSync() async throws {
        let sync = try SidecarPayload.decodeSync(stdout: Self.successJSON, exitCode: 0)
        let result = try await SidecarPayload.decodeResultOffMain(stdout: Self.successJSON, exitCode: 0)
        #expect(result.cells.count == sync.cells.count)
        #expect(result.imageWidth == sync.imageWidth)
        #expect(result.cells.map { $0.cx } == sync.cells.map { $0.cx })
    }

    private func failure(_ data: Data, exitCode: Int32 = 7,
                         isolating: Bool = false) async -> (Int32, String)? {
        do {
            _ = try await SidecarPayload.decodeResultOffMain(stdout: data, exitCode: exitCode,
                                                      isolatingJSON: isolating)
            return nil
        } catch DetectionError.sidecarFailed(let code, let text) {
            return (code, text)
        } catch {
            return (-999, "\(error)")
        }
    }

    @Test func errorObjectWinsAndReportsExitCodeZero() async {
        let data = Data(#"{"error": "model not found", "hint": "install it"}"#.utf8)
        let f = await failure(data)
        #expect(f?.0 == 0)
        #expect(f?.1 == "model not found: install it")

        let noHint = await failure(Data(#"{"error": "boom"}"#.utf8))
        #expect(noHint?.1 == "boom")

        // An error object takes precedence even when payload fields exist.
        let both = await failure(Data(#"{"error": "x", "width": 1, "height": 1, "cells": []}"#.utf8))
        #expect(both?.1 == "x")
    }

    @Test func malformedOutputIsUnparseable() async {
        let garbage = await failure(Data("not json at all".utf8))
        #expect(garbage?.0 == 7)
        #expect(garbage?.1 == "Unparseable stdout: not json at all")

        // Valid JSON of the wrong shape, and an error object with a bad hint
        // type, are both unparseable rather than structured errors.
        let wrongShape = await failure(Data(#"{"width": 1}"#.utf8))
        #expect(wrongShape?.1.hasPrefix("Unparseable stdout:") == true)
        let badHint = await failure(Data(#"{"error": "x", "hint": 3}"#.utf8))
        #expect(badHint?.1.hasPrefix("Unparseable stdout:") == true)
        let array = await failure(Data("[]".utf8))
        #expect(array?.1 == "Unparseable stdout: []")
        let empty = await failure(Data())
        #expect(empty?.1 == "Unparseable stdout: ")
    }

    @Test func bannerBeforeJSONOnlyDecodesWhenIsolating() async throws {
        let banner = Data("Found model 'x'.\nLoading weights.\n".utf8) + Self.successJSON
        let plain = await failure(banner)
        #expect(plain?.1.hasPrefix("Unparseable stdout:") == true)
        let r = try await SidecarPayload.decodeResultOffMain(stdout: banner, exitCode: 0, isolatingJSON: true)
        #expect(r.cells.count == 2)

        let bannerError = Data("log line\n".utf8) + Data(#"{"error": "e"}"#.utf8)
        let f = await failure(bannerError, isolating: true)
        #expect(f?.1 == "e")

        // Nothing decodable: original bytes are echoed in the message.
        let junk = await failure(Data("hello {oops".utf8), isolating: true)
        #expect(junk?.1 == "Unparseable stdout: hello {oops")
    }

    // MARK: — Ensemble grid matching

    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private func cell(_ x: Double, _ y: Double, _ d: Double = 10) -> DetectedCell {
        DetectedCell(cx: x, cy: y, diameter: d, diameterPx: d)
    }

    private func assertSame(_ x: EnsembleMatcher.Result, _ y: EnsembleMatcher.Result,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(x.agreed.map { [$0.a.id, $0.b.id] } == y.agreed.map { [$0.a.id, $0.b.id] },
                sourceLocation: sourceLocation)
        #expect(x.agreed.map(\.distancePx) == y.agreed.map(\.distancePx), sourceLocation: sourceLocation)
        #expect(x.onlyA.map(\.id) == y.onlyA.map(\.id), sourceLocation: sourceLocation)
        #expect(x.onlyB.map(\.id) == y.onlyB.map(\.id), sourceLocation: sourceLocation)
    }

    @Test func gridMatchesBruteForceOnRandomFields() {
        for seed in 1...20 {
            var rng = LCG(state: UInt64(seed))
            let n = 40 + seed * 10
            let a = (0..<n).map { _ in cell(rng.next() * 400, rng.next() * 400, 4 + rng.next() * 30) }
            let b = (0..<n).map { _ in cell(rng.next() * 400, rng.next() * 400, 4 + rng.next() * 30) }
            for factor in [0.5, 1.0, 2.5] {
                assertSame(EnsembleMatcher.match(a: a, b: b, matchRadiusFactor: factor),
                           EnsembleMatcher.matchBruteForce(a: a, b: b, matchRadiusFactor: factor))
            }
        }
    }

    @Test func gridMatchesBruteForceOnTiesAndRadiusBoundary() {
        // Cells exactly at the radius (10 apart, diameter 10) match; just past do not.
        let a = [cell(0, 0), cell(100, 100), cell(-50, -50)]
        let b = [cell(10, 0), cell(100, 110.0000001), cell(-50, -40)]
        let g = EnsembleMatcher.match(a: a, b: b)
        assertSame(g, EnsembleMatcher.matchBruteForce(a: a, b: b))
        #expect(g.agreed.count == 2)
        #expect(g.onlyA.map(\.id) == [a[1].id])

        // Two A cells equidistant from one B cell, and mirror-image ties on a
        // bucket edge (negative coordinates included).
        let a2 = [cell(0, 0), cell(10, 0), cell(-10, 0), cell(0, 10)]
        let b2 = [cell(5, 0), cell(-5, 0), cell(0, 5)]
        assertSame(EnsembleMatcher.match(a: a2, b: b2),
                   EnsembleMatcher.matchBruteForce(a: a2, b: b2))

        // Lattice with many equal distances.
        var a3: [DetectedCell] = [], b3: [DetectedCell] = []
        for i in 0..<12 { for j in 0..<12 {
            a3.append(cell(Double(i) * 7, Double(j) * 7))
            b3.append(cell(Double(i) * 7 + 3.5, Double(j) * 7 + 3.5))
        } }
        for factor in [0.4, 0.7, 1.0, 1.5] {
            assertSame(EnsembleMatcher.match(a: a3, b: b3, matchRadiusFactor: factor),
                       EnsembleMatcher.matchBruteForce(a: a3, b: b3, matchRadiusFactor: factor))
        }
    }

    @Test func gridMatchesBruteForceOnDegenerateInputs() {
        let a = [cell(.nan, 0), cell(1, 1), cell(1e15, 1e15), cell(2, 2, 0)]
        let b = [cell(1, 1), cell(.infinity, 0), cell(1e15, 1e15), cell(2.5, 2, -3)]
        assertSame(EnsembleMatcher.match(a: a, b: b), EnsembleMatcher.matchBruteForce(a: a, b: b))
        assertSame(EnsembleMatcher.match(a: a, b: b, matchRadiusFactor: 0),
                   EnsembleMatcher.matchBruteForce(a: a, b: b, matchRadiusFactor: 0))
        let wide = [cell(0, 0, .infinity)]
        assertSame(EnsembleMatcher.match(a: wide, b: b), EnsembleMatcher.matchBruteForce(a: wide, b: b))
        assertSame(EnsembleMatcher.match(a: [], b: b), EnsembleMatcher.matchBruteForce(a: [], b: b))
    }

    @Test func offMainMatchEqualsDirect() async {
        var rng = LCG(state: 99)
        let a = (0..<100).map { _ in cell(rng.next() * 200, rng.next() * 200) }
        let b = (0..<100).map { _ in cell(rng.next() * 200, rng.next() * 200) }
        let r = await EnsembleMatcher.matchOffMain(a: a, b: b)
        assertSame(r, EnsembleMatcher.matchBruteForce(a: a, b: b))
    }
}
