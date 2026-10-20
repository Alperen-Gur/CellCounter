import SwiftUI
import WebKit

/// The web view can read only these bundled renderer assets. It has no project
/// file access; numerical operations and exact-plane edits remain in the session.
struct WorkbenchVolumeWebView: NSViewRepresentable {
    let descriptor: WorkbenchJSON?
    let descriptorIdentity: String
    let generation: Int
    let crosshair: [Int]
    let onPointer: ([Double], String?, Int) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPointer: onPointer, onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "cellcounter-volume")
        configuration.userContentController.add(context.coordinator, name: "cellcounterVolume")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        view.load(URLRequest(url: URL(string: "cellcounter-volume://viewer/index.html")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onPointer = onPointer
        context.coordinator.onStatus = onStatus
        context.coordinator.update(descriptor: descriptor, identity: descriptorIdentity,
                                   generation: generation, crosshair: crosshair)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "cellcounterVolume")
        view.stopLoading()
        view.navigationDelegate = nil
        coordinator.webView = nil
        coordinator.pending = nil
    }

    @MainActor final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
        static let assets: [String: String] = [
            "index.html": "text/html", "host.js": "text/javascript",
            "volume-viewer.js": "text/javascript", "math.js": "text/javascript",
            "volume-viewer.css": "text/css"
        ]
        weak var webView: WKWebView?
        var onPointer: ([Double], String?, Int) -> Void
        var onStatus: (String) -> Void
        var pending: (descriptor: WorkbenchJSON, identity: String, generation: Int, crosshair: [Int])?
        var ready = false
        var sentGeneration: Int?
        var sentIdentity: String?
        var rendererGeneration = 0
        var sentCrosshair: [Int] = []

        init(onPointer: @escaping ([Double], String?, Int) -> Void,
             onStatus: @escaping (String) -> Void) {
            self.onPointer = onPointer; self.onStatus = onStatus
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  url.scheme == "cellcounter-volume", url.host == "viewer",
                  url.query == nil, url.fragment == nil,
                  let mime = Self.assets[String(url.path.dropFirst())],
                  let resource = Bundle.main.resourceURL?
                    .appendingPathComponent("volume-viewer", isDirectory: true)
                    .appendingPathComponent(String(url.path.dropFirst())),
                  let data = try? Data(contentsOf: resource) else {
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
                return
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime,
                expectedContentLength: data.count, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = navigationAction.request.url?.absoluteString == "cellcounter-volume://viewer/index.html"
            decisionHandler(allowed && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            onStatus("Volume renderer could not load: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: any Error) {
            onStatus("Volume renderer could not load: \(error.localizedDescription)")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            if type == "ready" { ready = true; sendPending(); return }
            guard let pending, let received = body["generation"] as? Int,
                  received == rendererGeneration, pending.generation == sentGeneration,
                  pending.identity == sentIdentity else { return }
            if type == "status", let message = body["message"] as? String {
                onStatus(message)
            } else if type == "planePointer" || type == "crosshair",
                      let voxel = body["voxel"] as? [Double], voxel.count == 3, voxel.allSatisfy(\.isFinite) {
                onPointer(voxel, body["plane"] as? String, pending.generation)
            }
        }

        func update(descriptor: WorkbenchJSON?, identity: String, generation: Int, crosshair: [Int]) {
            guard let descriptor else {
                if pending != nil {
                    rendererGeneration += 1
                    pending = nil
                    sentIdentity = nil
                }
                return
            }
            pending = (descriptor, identity, generation, crosshair)
            sendPending()
        }

        private func sendPending() {
            guard ready, let pending, let webView else { return }
            if sentGeneration != pending.generation || sentIdentity != pending.identity {
                rendererGeneration += 1
                let rendererToken = rendererGeneration
                sentGeneration = pending.generation
                sentIdentity = pending.identity
                sentCrosshair = pending.crosshair
                webView.callAsyncJavaScript(
                    "window.cellcounterVolume.setGeneration(generation); await window.cellcounterVolume.setVolume(descriptor); window.cellcounterVolume.setCrosshair(crosshair);",
                    arguments: ["descriptor": pending.descriptor.foundationValue,
                                "generation": rendererToken, "crosshair": pending.crosshair],
                    in: nil, in: .page) { [weak self] result in
                        guard let self, self.rendererGeneration == rendererToken,
                              self.pending?.generation == pending.generation,
                              self.pending?.identity == pending.identity else { return }
                        if case .failure(let error) = result {
                            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                                ?? error.localizedDescription
                            self.onStatus("Volume rendering failed: \(detail)")
                        }
                    }
            } else if sentCrosshair != pending.crosshair {
                sentCrosshair = pending.crosshair
                webView.callAsyncJavaScript("window.cellcounterVolume.setCrosshair(crosshair);",
                    arguments: ["crosshair": pending.crosshair], in: nil, in: .page,
                    completionHandler: nil)
            }
        }
    }
}

private extension WorkbenchJSON {
    var foundationValue: Any {
        switch self {
        case .object(let values): return values.mapValues(\.foundationValue)
        case .array(let values): return values.map(\.foundationValue)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}
