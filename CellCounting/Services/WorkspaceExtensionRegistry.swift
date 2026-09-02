import Foundation

nonisolated enum WorkspaceExtensionKind: String, Codable, CaseIterable, Sendable {
    case reader, detector, assay, measurement, exporter

    var displayName: String { rawValue.capitalized }
}

nonisolated enum WorkspaceExtensionCapability: String, Codable, CaseIterable, Sendable {
    case readCommonImages
    case readVendorImages
    case readOMEZarr
    case detectCellpose
    case detectStarDist
    case classicalSegmentation
    case measureMorphology
    case measureIntensity
    case measureSpatial
    case exportTables
    case exportROIs
    case exportAnimation
}

nonisolated struct WorkspaceExtensionDescriptor: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var version: String
    var kind: WorkspaceExtensionKind
    var summary: String
    var capabilities: Set<WorkspaceExtensionCapability>
    var minimumWorkspaceSchema: Int = 1
    var publisher: String = "CellCounter Project"
    var isBundled: Bool = true
}

nonisolated enum WorkspaceExtensionError: LocalizedError, Equatable {
    case invalidIdentifier
    case untrustedPublisher
    case executableExtensionsUnavailable
    case incompatibleSchema(Int)
    case duplicateIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "The extension identifier is invalid."
        case .untrustedPublisher: return "Only extensions curated by CellCounter are accepted in this release."
        case .executableExtensionsUnavailable: return "Executable third-party plugins are not supported."
        case .incompatibleSchema(let version): return "This extension requires workspace schema \(version)."
        case .duplicateIdentifier: return "An extension with this identifier is already registered."
        }
    }
}

/// A capability registry, not a code loader. Descriptors expose built-in modules through a
/// stable contract while preserving the app's local-only and deterministic execution boundary.
actor WorkspaceExtensionRegistry {
    static let shared = WorkspaceExtensionRegistry()

    private var descriptors: [String: WorkspaceExtensionDescriptor]

    init(descriptors: [WorkspaceExtensionDescriptor] = WorkspaceExtensionRegistry.bundled) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    func all(kind: WorkspaceExtensionKind? = nil) -> [WorkspaceExtensionDescriptor] {
        descriptors.values
            .filter { kind == nil || $0.kind == kind }
            .sorted { lhs, rhs in
                lhs.kind == rhs.kind ? lhs.name < rhs.name : lhs.kind.rawValue < rhs.kind.rawValue
            }
    }

    func extensionProviding(_ capability: WorkspaceExtensionCapability) -> WorkspaceExtensionDescriptor? {
        descriptors.values.first { $0.capabilities.contains(capability) }
    }

    func registerCurated(_ descriptor: WorkspaceExtensionDescriptor) throws {
        guard descriptor.id.range(of: #"^org\.cellcounter\.[a-z0-9.-]+$"#,
                                  options: .regularExpression) != nil else {
            throw WorkspaceExtensionError.invalidIdentifier
        }
        guard descriptor.publisher == "CellCounter Project", descriptor.isBundled else {
            throw WorkspaceExtensionError.untrustedPublisher
        }
        guard descriptor.minimumWorkspaceSchema <= MicroscopyWorkspace.currentSchemaVersion else {
            throw WorkspaceExtensionError.incompatibleSchema(descriptor.minimumWorkspaceSchema)
        }
        guard descriptors[descriptor.id] == nil else { throw WorkspaceExtensionError.duplicateIdentifier }
        descriptors[descriptor.id] = descriptor
    }

    /// Deliberately refuses executable paths, URLs, scripts, and dynamic libraries.
    func installExecutable(at _: URL) throws -> Never {
        throw WorkspaceExtensionError.executableExtensionsUnavailable
    }

    static let bundled: [WorkspaceExtensionDescriptor] = [
        .init(id: "org.cellcounter.reader.imageio", name: "Common microscopy images",
              version: "1.0", kind: .reader,
              summary: "Local TIFF, OME-TIFF, PNG, JPEG, and BMP import.",
              capabilities: [.readCommonImages]),
        .init(id: "org.cellcounter.reader.vendor", name: "Microscope containers",
              version: "1.0", kind: .reader,
              summary: "Local ND2, CZI, LIF, OIF, OIB, and OIR preparation.",
              capabilities: [.readVendorImages]),
        .init(id: "org.cellcounter.reader.omezarr", name: "OME-Zarr / NGFF",
              version: "1.0", kind: .reader,
              summary: "Local multiscale arrays, plates, wells, fields, and supported chunks.",
              capabilities: [.readOMEZarr]),
        .init(id: "org.cellcounter.detector.cellpose", name: "Cellpose families",
              version: "1.0", kind: .detector,
              summary: "Cellpose-SAM, cyto3, nuclei, Omnipose, and compatible local checkpoints.",
              capabilities: [.detectCellpose]),
        .init(id: "org.cellcounter.detector.stardist", name: "StarDist",
              version: "1.0", kind: .detector,
              summary: "Local StarDist fluorescence segmentation.",
              capabilities: [.detectStarDist]),
        .init(id: "org.cellcounter.detector.classical", name: "Classical segmentation",
              version: "1.0", kind: .detector,
              summary: "Deterministic threshold and watershed segmentation.",
              capabilities: [.classicalSegmentation]),
        .init(id: "org.cellcounter.measurement.morphology", name: "Morphology",
              version: "1.0", kind: .measurement,
              summary: "Calibrated cell shape, size, and spatial measurements.",
              capabilities: [.measureMorphology, .measureSpatial]),
        .init(id: "org.cellcounter.assay.fluorescence", name: "Fluorescence assays",
              version: "1.0", kind: .assay,
              summary: "Intensity, marker, colocalization, puncta, and viability assays.",
              capabilities: [.measureIntensity]),
        .init(id: "org.cellcounter.export.tables", name: "Tables and provenance",
              version: "1.0", kind: .exporter,
              summary: "CSV, JSON, ROI, and GeoJSON exports.",
              capabilities: [.exportTables, .exportROIs]),
        .init(id: "org.cellcounter.export.animation", name: "Workspace animation",
              version: "1.0", kind: .exporter,
              summary: "Local publication-ready GIF sequences from workspace frames.",
              capabilities: [.exportAnimation]),
    ]
}
