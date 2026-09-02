import Foundation
import Testing
@testable import CellCounting

struct EcosystemFeatureTests {
    @Test func workspaceRoundTripPreservesNDimensionalLayersAndTransforms() throws {
        let time = WorkspaceAxis(name: "Time", kind: .time, length: 12, unit: "s", scale: 2)
        let channel = WorkspaceAxis(name: "Channel", kind: .channel, length: 3)
        var workspace = MicroscopyWorkspace(name: "Time course", axes: [time, channel])
        workspace.updatePosition(axisID: time.id, index: 99)

        let layer = WorkspaceLayer(
            name: "Nuclei", kind: .image,
            source: .localFile(bookmarkID: nil, displayName: "nuclei.tif"),
            payload: .raster, axisIDs: [time.id, channel.id], opacity: 2,
            transform: .translation(x: 4, y: -3))
        workspace.addLayer(layer)

        #expect(workspace.position[time.id] == 11)
        #expect(workspace.layers.first?.opacity == 1)
        #expect(workspace.layers.first?.transform.applying(
            to: WorkspaceCoordinate(x: 1, y: 1)) == WorkspaceCoordinate(x: 5, y: -2))
        #expect(workspace.validationIssues().isEmpty)

        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspace.ccworkspace.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try WorkspaceDocumentStore.save(workspace, to: url)
        let restored = try WorkspaceDocumentStore.load(from: url)
        #expect(restored.id == workspace.id)
        #expect(restored.name == workspace.name)
        #expect(restored.axes == workspace.axes)
        #expect(restored.position == workspace.position)
        #expect(restored.layers == workspace.layers)
        #expect(restored.validationIssues().isEmpty)
    }

    @Test func lineageSupportsDivisionAndMergeWhileRejectingInvalidLinks() throws {
        let parent = WorkspaceLineageNode(frame: 0, coordinate: .init(x: 1, y: 1))
        let sibling = WorkspaceLineageNode(frame: 0, coordinate: .init(x: 8, y: 1))
        let childA = WorkspaceLineageNode(frame: 1, coordinate: .init(x: 2, y: 2))
        let childB = WorkspaceLineageNode(frame: 1, coordinate: .init(x: 3, y: 2))
        var graph = WorkspaceLineageGraph(nodes: [parent, sibling, childA, childB])

        try graph.link(parentID: parent.id, childID: childA.id, kind: .division)
        try graph.link(parentID: parent.id, childID: childB.id, kind: .division)
        try graph.link(parentID: sibling.id, childID: childB.id, kind: .merge)

        #expect(graph.children(of: parent.id).count == 2)
        #expect(graph.parents(of: childB.id).count == 2)
        #expect(graph.validationIssues().isEmpty)
        #expect(throws: WorkspaceLineageError.invalidTimeOrder) {
            try graph.link(parentID: childA.id, childID: parent.id)
        }
        #expect(throws: WorkspaceLineageError.duplicateEdge) {
            try graph.link(parentID: parent.id, childID: childA.id)
        }
    }

    @Test func trainByPaintingRasterizesPerPositionAndSupportsErase() {
        let axisID = UUID()
        var firstPosition = WorkspacePosition()
        firstPosition[axisID] = 0
        var secondPosition = WorkspacePosition()
        secondPosition[axisID] = 1
        var document = WorkspacePaintDocument(
            width: 12, height: 12,
            classes: [.init(value: 7, name: "Cell", colorHex: "#00FF00")])
        document.append(.init(classValue: 7, radiusPx: 2,
                              points: [.init(x: 6, y: 6)], position: firstPosition))
        document.append(.init(classValue: 7, radiusPx: 1,
                              points: [.init(x: 1, y: 1)], position: secondPosition))
        document.append(.init(classValue: 7, radiusPx: 0.75,
                              points: [.init(x: 6, y: 6)], position: firstPosition, erases: true))

        let first = document.rasterized(at: firstPosition)
        let second = document.rasterized(at: secondPosition)
        #expect(first[6 * 12 + 6] == 0)
        #expect(first.contains(7))
        #expect(second[1 * 12 + 1] == 7)
    }

    @Test func readsLocalOMEZarrPlaneAndPhysicalAxes() async throws {
        let root = temporaryDirectory().appendingPathComponent("plate.ome.zarr", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("0"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let attributes = """
        {"multiscales":[{"name":"Demo","axes":[
          {"name":"y","type":"space","unit":"micrometer"},
          {"name":"x","type":"space","unit":"micrometer"}],
          "datasets":[{"path":"0","coordinateTransformations":[{"type":"scale","scale":[0.5,0.25]}]}]}]}
        """
        let array = """
        {"zarr_format":2,"shape":[2,3],"chunks":[2,3],"dtype":"|u1",
         "compressor":null,"fill_value":0,"order":"C","filters":null,"dimension_separator":"."}
        """
        try Data(attributes.utf8).write(to: root.appendingPathComponent(".zattrs"))
        try Data(array.utf8).write(to: root.appendingPathComponent("0/.zarray"))
        try Data([1, 2, 3, 4, 5, 6]).write(to: root.appendingPathComponent("0/0.0"))

        let dataset = try await OMEZarrService.shared.inspect(rootURL: root, useCache: false)
        let descriptor = try #require(dataset.arrays.first)
        let plane = try await OMEZarrService.shared.readPlane(array: descriptor)
        #expect(dataset.name == "Demo")
        #expect(descriptor.axes.map(\.kind) == [.y, .x])
        #expect(descriptor.coordinateScale == [0.5, 0.25])
        #expect(plane.width == 3)
        #expect(plane.height == 2)
        #expect(plane.pixels == [1, 2, 3, 4, 5, 6])
    }

    @Test func rejectsUnsafeOMEZarrDatasetPaths() async throws {
        let root = temporaryDirectory().appendingPathComponent("unsafe.ome.zarr", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let attributes = """
        {"multiscales":[{"datasets":[{"path":"../private"}]}]}
        """
        try Data(attributes.utf8).write(to: root.appendingPathComponent(".zattrs"))
        await #expect(throws: OMEZarrError.unsafePath("../private")) {
            try await OMEZarrService.shared.inspect(rootURL: root, useCache: false)
        }
    }

    @Test func registrationAndStitchingAreDeterministic() throws {
        let width = 24
        let height = 20
        let referencePixels = (0..<(width * height)).map { index -> Float in
            let x = index % width
            let y = index / width
            return Float((x * 17 + y * 31 + x * y * 3) % 101) / 100
        }
        let reference = WorkspacePixelPlane(width: width, height: height, pixels: referencePixels)
        let movingPixels = (0..<(width * height)).map { index -> Float in
            let x = index % width
            let y = index / width
            return (x + 2 < width && y + 1 < height) ? reference[x + 2, y + 1] : 0
        }
        let moving = WorkspacePixelPlane(width: width, height: height, pixels: movingPixels)
        let registration = try ImageRegistrationService.estimateTranslation(
            reference: reference, moving: moving, maxShift: 5)
        #expect(registration.transform.tx == 2)
        #expect(registration.transform.ty == 1)
        #expect(registration.score > 0.99)

        let left = WorkspacePixelPlane(width: 2, height: 2, pixels: [1, 1, 1, 1])
        let right = WorkspacePixelPlane(width: 2, height: 2, pixels: [2, 2, 2, 2])
        let stitched = try ImageRegistrationService.stitch(tiles: [
            .init(plane: left),
            .init(plane: right, transform: .translation(x: 2, y: 0)),
        ])
        #expect(stitched.plane.width == 4)
        #expect(stitched.plane.height == 2)
        #expect(stitched.plane.pixels == [1, 1, 2, 2, 1, 1, 2, 2])
    }

    @Test func recordedWorkflowReplaysWithoutExecutableScripting() async throws {
        let axis = WorkspaceAxis(name: "Z", kind: .z, length: 5)
        let layer = WorkspaceLayer(name: "Cells", kind: .labels,
                                   source: .generated(operation: "test"), payload: .raster,
                                   axisIDs: [axis.id])
        var workspace = MicroscopyWorkspace(name: "Workflow", axes: [axis])
        workspace.addLayer(layer)
        let workflow = WorkspaceWorkflow(name: "Presentation", steps: [
            .setLayerOpacity(id: layer.id, opacity: 0.4),
            .setLayerVisibility(id: layer.id, visible: false),
            .translateLayer(id: layer.id, x: 3, y: 2),
            .selectAxis(axisID: axis.id, index: 4),
        ])

        let result = try await WorkspaceWorkflowService().execute(
            workflow, context: .init(workspace: workspace, planes: [:]))
        let updated = try #require(result.workspace.layers.first)
        #expect(updated.opacity == 0.4)
        #expect(!updated.isVisible)
        #expect(updated.transform.tx == 3)
        #expect(updated.transform.ty == 2)
        #expect(result.workspace.position[axis.id] == 4)
    }

    @Test func curatedExtensionsExposeCapabilitiesAndRefuseCodeLoading() async throws {
        let registry = WorkspaceExtensionRegistry()
        let zarr = await registry.extensionProviding(.readOMEZarr)
        #expect(zarr?.kind == .reader)
        do {
            _ = try await registry.installExecutable(at: URL(fileURLWithPath: "/tmp/plugin.dylib"))
            Issue.record("Executable plugins must remain outside the curated capability boundary")
        } catch let error as WorkspaceExtensionError {
            #expect(error == .executableExtensionsUnavailable)
        }
    }

    @Test func animationInterpolatesAxesCameraAndVisibility() throws {
        let axisID = UUID()
        let firstLayer = UUID()
        let secondLayer = UUID()
        let plan = WorkspaceAnimationPlan(name: "Z sweep", framesPerSecond: 2, easing: .linear,
                                          keyframes: [
            .init(timeSeconds: 0, position: .init(indices: [axisID: 0]), zoom: 1,
                  center: .init(x: 0, y: 0), visibleLayerIDs: [firstLayer]),
            .init(timeSeconds: 1, position: .init(indices: [axisID: 4]), zoom: 3,
                  center: .init(x: 1, y: 1), visibleLayerIDs: [secondLayer]),
        ])
        let frames = try WorkspaceAnimationService.frameStates(for: plan)
        #expect(frames.count == 3)
        #expect(frames[1].position[axisID] == 2)
        #expect(frames[1].zoom == 2)
        #expect(frames[1].center == WorkspaceCoordinate(x: 0.5, y: 0.5))
        #expect(frames.last?.visibleLayerIDs == [secondLayer])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-ecosystem-\(UUID().uuidString)", isDirectory: true)
    }
}
