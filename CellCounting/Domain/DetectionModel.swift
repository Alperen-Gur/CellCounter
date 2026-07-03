import Foundation

enum ModelFamily: String, CaseIterable, Identifiable {
    case all = "All"
    case cellpose = "Cellpose"
    /// Pass-16: Cellpose 4.x / CPSAM. Lives in `venv4/` and is installed
    /// independently of the 3.x family. The user picks between the two in
    /// the Models tab. Kept as a separate case so the Models filter chips
    /// and per-family icons can distinguish them.
    case cellpose4 = "Cellpose-SAM"
    case stardist = "StarDist"
    case sam = "SAM-family"
    case custom = "Custom"
    var id: String { rawValue }
}

enum ModelState: String {
    case active, downloaded, off
}

enum ModelSpeed: String { case fast, med, slow }
enum ModelAccuracy: String { case low, med, high }

struct DetectionModelInfo: Identifiable, Hashable {
    let id: String
    let family: ModelFamily
    let name: String
    let sizeMB: Int
    let sizeLabel: String
    let desc: String
    var state: ModelState
    let speed: ModelSpeed
    let accuracy: ModelAccuracy
    let tags: [String]
    var builtIn: Bool = false
    var recommended: Bool = false
    var custom: Bool = false
    var license: String? = nil
    var note: String? = nil

    /// Architecture / training data / paper / license — surfaced in info popover.
    var architecture: String = ""
    var trainingData: String = ""
    var paper: String = ""
    var outputType: String = "Masks + boxes"

    /// Pass-19: model is in the catalog for visibility but not yet verified
    /// end-to-end on the user's hardware. ModelsView shows a "Coming soon"
    /// chip in lieu of the install/activate buttons; AppState.activate()
    /// refuses these as defense-in-depth.
    var comingSoon: Bool = false
}

enum ModelCatalog {
    static let builtIn: [DetectionModelInfo] = [
        .init(id: "cp-cyto3", family: .cellpose, name: "Cellpose cyto3",
              sizeMB: 26, sizeLabel: "26 MB",
              desc: "General-purpose, all cell types. Recommended default.",
              state: .off, speed: .fast, accuracy: .high,
              tags: ["bf", "phase", "fluor"], builtIn: true,
              architecture: "U-Net (Cellpose)",
              trainingData: "Cellpose 2.0 training set + new generalist data",
              paper: "Stringer et al. — Cellpose 2.0 (Nature Methods, 2022)",
              outputType: "Masks + boxes + outlines"),
        .init(id: "cp-nuclei", family: .cellpose, name: "Cellpose nuclei",
              sizeMB: 26, sizeLabel: "26 MB",
              desc: "Nuclei only (DAPI / Hoechst).",
              state: .off, speed: .fast, accuracy: .high,
              tags: ["fluor"], builtIn: true,
              architecture: "U-Net (Cellpose)",
              trainingData: "Nuclei subset (DAPI, Hoechst)",
              paper: "Stringer et al. — Cellpose (Nature Methods, 2020)",
              outputType: "Masks + boxes + outlines"),
    ]

    static let cellpose: [DetectionModelInfo] = [
        .init(id: "cp-cyto3-r", family: .cellpose, name: "Cellpose cyto3 + restore",
              sizeMB: 55, sizeLabel: "55 MB",
              desc: "Adds image restoration for noisy or low-contrast inputs. Slower.",
              state: .off, speed: .med, accuracy: .high,
              tags: ["bf", "phase"],
              architecture: "U-Net + restoration head",
              trainingData: "Cellpose 3.0 set + restoration pairs",
              paper: "Stringer & Pachitariu — Cellpose 3 (2024)",
              outputType: "Masks + boxes + outlines"),
        .init(id: "cp-cyto2", family: .cellpose, name: "Cellpose cyto2",
              sizeMB: 26, sizeLabel: "26 MB",
              desc: "Previous-gen general model. Keep for reproducing older results.",
              state: .off, speed: .fast, accuracy: .med,
              tags: ["bf"],
              architecture: "U-Net (Cellpose)",
              trainingData: "Cellpose 2.0 set",
              paper: "Pachitariu & Stringer — Cellpose 2 (2022)",
              outputType: "Masks + boxes + outlines"),
    ]

    /// Pass-16: Cellpose-SAM (4.x / CPSAM). Single model id today; the install
    /// pulls a separate `venv4/` and downloads ~1.15 GB of CPSAM weights on
    /// first detection run. Kept in its own list so `ModelFamily.cellpose4`
    /// filtering in the Models view stays trivial.
    static let cellpose4: [DetectionModelInfo] = [
        .init(id: "cpsam", family: .cellpose4, name: "Cellpose-SAM",
              sizeMB: 1150, sizeLabel: "1.15 GB weights · ~3.5 GB total",
              desc: "2025 SAM-based segmenter. Heavy (~3.5 GB) but allegedly no tuning needed.",
              state: .off, speed: .slow, accuracy: .high,
              tags: ["fluor", "bf", "phase", "histo"],
              architecture: "SAM ViT encoder (Cellpose-SAM / CPSAM)",
              trainingData: "Cellpose-SAM generalist set (2025)",
              paper: "Stringer & Pachitariu — Cellpose-SAM (2025)",
              outputType: "Masks + boxes + outlines"),
    ]

    static let stardist: [DetectionModelInfo] = [
        .init(id: "sd-fluo", family: .stardist, name: "StarDist 2D versatile fluo",
              sizeMB: 10, sizeLabel: "10 MB",
              desc: "Fluorescent nuclei. Very fast.",
              state: .off, speed: .fast, accuracy: .high,
              tags: ["fluor"],
              architecture: "U-Net + star-convex polygons",
              trainingData: "DSB2018 + curated fluorescence",
              paper: "Schmidt et al. — StarDist (MICCAI 2018)",
              outputType: "Masks + boxes", comingSoon: true),
        .init(id: "sd-he", family: .stardist, name: "StarDist 2D versatile H&E",
              sizeMB: 10, sizeLabel: "10 MB",
              desc: "H&E-stained histology.",
              state: .off, speed: .fast, accuracy: .high,
              tags: ["histo"],
              architecture: "U-Net + star-convex polygons",
              trainingData: "MoNuSeg, CoNSeP, custom H&E",
              paper: "Weigert et al. — StarDist 3D (WACV 2020)",
              outputType: "Masks + boxes", comingSoon: true),
        .init(id: "sd-dsb", family: .stardist, name: "StarDist 2D DSB2018",
              sizeMB: 10, sizeLabel: "10 MB",
              desc: "Trained on Kaggle DSB nuclei.",
              state: .off, speed: .fast, accuracy: .med,
              tags: ["fluor"],
              architecture: "U-Net + star-convex polygons",
              trainingData: "Kaggle 2018 Data Science Bowl nuclei",
              paper: "Schmidt et al. — StarDist (MICCAI 2018)",
              outputType: "Masks + boxes", comingSoon: true),
    ]

    static let sam: [DetectionModelInfo] = [
        .init(id: "mobilesam", family: .sam, name: "MobileSAM",
              sizeMB: 40, sizeLabel: "40 MB",
              desc: "Lightweight SAM. Faster, less accurate than full SAM variants.",
              state: .off, speed: .med, accuracy: .med,
              tags: ["any"],
              architecture: "TinyViT encoder + SAM decoder",
              trainingData: "SA-1B (distilled)",
              paper: "Zhang et al. — MobileSAM (2023)",
              outputType: "Masks + boxes", comingSoon: true),
        .init(id: "usam-lm", family: .sam, name: "μSAM LM-generalist",
              sizeMB: 95, sizeLabel: "95 MB",
              desc: "Foundation-class model for light microscopy. Slow, very general.",
              state: .off, speed: .slow, accuracy: .high,
              tags: ["bf", "phase", "fluor"],
              architecture: "ViT-B + SAM decoder",
              trainingData: "Light microscopy benchmarks",
              paper: "Archit et al. — Segment Anything for Microscopy (2024)",
              outputType: "Masks + boxes", comingSoon: true),
        .init(id: "usam-em", family: .sam, name: "μSAM EM-generalist",
              sizeMB: 95, sizeLabel: "95 MB",
              desc: "Same family, trained on electron microscopy data.",
              state: .off, speed: .slow, accuracy: .high,
              tags: ["em"],
              architecture: "ViT-B + SAM decoder",
              trainingData: "EM benchmarks",
              paper: "Archit et al. — Segment Anything for Microscopy (2024)",
              outputType: "Masks + boxes", comingSoon: true),
        .init(id: "patho-sam", family: .sam, name: "patho-sam",
              sizeMB: 95, sizeLabel: "95 MB",
              desc: "μSAM variant for histopathology and H&E images.",
              state: .off, speed: .slow, accuracy: .high,
              tags: ["histo"],
              architecture: "μSAM (pathology fine-tune)",
              trainingData: "PanNuke + curated H&E",
              paper: "patho-sam — bioRxiv 2024",
              outputType: "Masks + boxes", comingSoon: true),
    ]

    static var all: [DetectionModelInfo] {
        builtIn + cellpose + cellpose4 + stardist + sam
    }
}
