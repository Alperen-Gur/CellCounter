import Foundation
import Testing
import WebKit
@testable import CellCounting

@Suite(.serialized) @MainActor
struct WorkbenchVolumeRendererTests {
    @Test func bundledRendererLoadsThroughRestrictedSchemeAndAcceptsVolume() async throws {
        var rendererStatus = ""
        let coordinator = WorkbenchVolumeWebView.Coordinator(
            onPointer: { _, _, _ in }, onStatus: { rendererStatus = $0 })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "cellcounter-volume")
        configuration.userContentController.add(coordinator, name: "cellcounterVolume")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 450), configuration: configuration)
        view.navigationDelegate = coordinator
        coordinator.webView = view
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "cellcounterVolume")
            view.stopLoading()
            view.navigationDelegate = nil
            coordinator.webView = nil
        }
        let url = try #require(URL(string: "cellcounter-volume://viewer/index.html"))
        view.load(URLRequest(url: url))
        for _ in 0..<500 {
            if coordinator.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(coordinator.ready, "Bundled JS modules must load through the restricted native scheme.")
        let descriptor: WorkbenchJSON = .object([
            "dataBase64": .string(Data(repeating: 128, count: 64).base64EncodedString()),
            "dtype": .string("uint8"), "encoding": .string("base64"), "order": .string("zyx"),
            "dimensions": .array([.number(4), .number(4), .number(4)]),
            "originalDimensions": .array([.number(4), .number(4), .number(4)]),
            "voxelSizeUm": .object(["x": .number(1), "y": .number(1), "z": .number(2)]),
            "displayRange": .array([.number(0), .number(255)]),
            "transform": .object(["scale": .array([.number(1), .number(1), .number(1)]),
                                   "offset": .array([.number(0), .number(0), .number(0)])])
        ])
        coordinator.update(descriptor: descriptor, identity: "fixture", generation: 42, crosshair: [1, 2, 3])
        for _ in 0..<250 {
            if !rendererStatus.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!rendererStatus.isEmpty)
        #expect(!rendererStatus.localizedCaseInsensitiveContains("failed"))
        #expect(coordinator.sentGeneration == 42)
        let canvasCount = try await view.callAsyncJavaScript("return document.querySelectorAll('canvas').length;",
            arguments: [:], in: nil, contentWorld: .page)
        #expect((canvasCount as? Int ?? 0) >= 4)
        coordinator.update(descriptor: descriptor, identity: "fixture", generation: 42, crosshair: [2, 1, 0])
        #expect(coordinator.sentCrosshair == [2, 1, 0])
    }
}
