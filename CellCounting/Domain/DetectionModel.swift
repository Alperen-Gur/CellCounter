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
    /// Omnipose — bacteria and filamentous / elongated cells. MIT licensed.
    /// Ships its own Cellpose fork (`cellpose_omni`) whose numpy/torch pins
    /// conflict with `cellpose>=4`, so it gets its OWN venv (`venv_omni/`),
    /// exactly like Cellpose-SAM gets `venv4/`. See `OmniposeDownloader`.
    case omnipose = "Omnipose"
    /// Classical threshold + watershed. No weights, no download, no GPU,
    /// no network — scikit-image only. Always available once the base Python
    /// environment exists, and deterministic run-to-run.
    case classical = "Classical"
    /// Two detectors run on the same image, their masks matched, and only the
    /// cells they DISAGREE about flagged for review. See `EnsembleDownloader`.
    case ensemble = "Ensemble"
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
        // The three entries below are the newer checkpoints documented at
        // https://cellpose.readthedocs.io/en/latest/models.html (verified
        // against that page). They are drop-in: same `venv4/` install, same
        // `pretrained_model=` constructor, same licence — the only difference
        // is the weights file cellpose downloads on first use. No extra
        // dependency and no extra disk beyond the per-model weights.
        .init(id: "cpsam_v2", family: .cellpose4, name: "Cellpose-SAM v2",
              sizeMB: 1150, sizeLabel: "~1.15 GB weights",
              desc: "Updated Cellpose-SAM with better handling of low-contrast regions. Same cost as cpsam.",
              state: .off, speed: .slow, accuracy: .high,
              tags: ["fluor", "bf", "phase", "histo"], recommended: false,
              architecture: "SAM ViT-L encoder (CellposeSAM v2)",
              trainingData: "Cellpose-SAM generalist set, revised",
              paper: "Stringer & Pachitariu — Cellpose-SAM (2025/2026 revision)",
              outputType: "Masks + boxes + outlines"),
        .init(id: "cpdino", family: .cellpose4, name: "Cellpose-DINO (ViT-L)",
              sizeMB: 1200, sizeLabel: "~1.2 GB weights",
              desc: "DINOv3-ViTL backbone instead of SAM. Supports adjustable tile size, so large fields tile more efficiently.",
              state: .off, speed: .slow, accuracy: .high,
              tags: ["fluor", "bf", "phase", "histo"],
              architecture: "DINOv3 ViT-L encoder (CellposeDINO)",
              trainingData: "Cellpose generalist set, DINOv3 backbone",
              paper: "Cellpose model zoo — CellposeDINO",
              outputType: "Masks + boxes + outlines"),
        .init(id: "cpdino-vitb", family: .cellpose4, name: "Cellpose-DINO (ViT-B)",
              sizeMB: 400, sizeLabel: "~400 MB weights",
              desc: "Smaller DINOv3-ViTB variant. Noticeably lighter and faster than the ViT-L models.",
              state: .off, speed: .med, accuracy: .high,
              tags: ["fluor", "bf", "phase"],
              architecture: "DINOv3 ViT-B encoder (CellposeDINO)",
              trainingData: "Cellpose generalist set, DINOv3 backbone",
              paper: "Cellpose model zoo — CellposeDINO",
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
              outputType: "Masks + boxes"),
        .init(id: "sd-he", family: .stardist, name: "StarDist 2D versatile H&E",
              sizeMB: 10, sizeLabel: "10 MB",
              desc: "H&E-stained histology.",
              state: .off, speed: .fast, accuracy: .high,
              tags: ["histo"],
              architecture: "U-Net + star-convex polygons",
              trainingData: "MoNuSeg, CoNSeP, custom H&E",
              paper: "Weigert et al. — StarDist 3D (WACV 2020)",
              outputType: "Masks + boxes"),
        .init(id: "sd-dsb", family: .stardist, name: "StarDist 2D DSB2018",
              sizeMB: 10, sizeLabel: "10 MB",
              desc: "Trained on Kaggle DSB nuclei.",
              state: .off, speed: .fast, accuracy: .med,
              tags: ["fluor"],
              architecture: "U-Net + star-convex polygons",
              trainingData: "Kaggle 2018 Data Science Bowl nuclei",
              paper: "Schmidt et al. — StarDist (MICCAI 2018)",
              outputType: "Masks + boxes"),
    ]

    /// Omnipose — the distance-field reformulation of Cellpose that drops the
    /// "cells are roughly round" assumption. This is the family to reach for
    /// with bacteria, filaments, and anything elongated, where Cellpose's
    /// diameter prior actively hurts. MIT licensed.
    ///
    /// Installs into its own `venv_omni/` (see `OmniposeDownloader`) because
    /// `omnipose` pulls `cellpose_omni` — a Cellpose fork whose numpy/torch
    /// pins conflict with the `cellpose>=4` stack in `venv4/`.
    static let omnipose: [DetectionModelInfo] = [
        .init(id: "omni-bact-phase", family: .omnipose, name: "Omnipose bact_phase",
              sizeMB: 26, sizeLabel: "26 MB weights · ~2 GB env",
              desc: "Bacteria in phase contrast. Handles filamentous and dividing cells that Cellpose merges.",
              state: .off, speed: .med, accuracy: .high,
              tags: ["phase", "bacteria"], recommended: false,
              license: "MIT",
              architecture: "U-Net + distance field (Omnipose)",
              trainingData: "Bacterial phase-contrast (BCM3D, Omnipose set)",
              paper: "Cutler et al. — Omnipose (Nature Methods, 2022)",
              outputType: "Masks + boxes + outlines"),
        .init(id: "omni-bact-fluor", family: .omnipose, name: "Omnipose bact_fluor",
              sizeMB: 26, sizeLabel: "26 MB weights · ~2 GB env",
              desc: "Bacteria in fluorescence. Same distance-field model, fluorescence training set.",
              state: .off, speed: .med, accuracy: .high,
              tags: ["fluor", "bacteria"],
              license: "MIT",
              architecture: "U-Net + distance field (Omnipose)",
              trainingData: "Bacterial fluorescence (Omnipose set)",
              paper: "Cutler et al. — Omnipose (Nature Methods, 2022)",
              outputType: "Masks + boxes + outlines"),
        .init(id: "omni-cyto2", family: .omnipose, name: "Omnipose cyto2",
              sizeMB: 26, sizeLabel: "26 MB weights · ~2 GB env",
              desc: "Eukaryotic cells with the Omnipose mask reconstruction. Better on irregular, non-round shapes.",
              state: .off, speed: .med, accuracy: .med,
              tags: ["bf", "phase", "fluor"],
              license: "MIT",
              architecture: "U-Net + distance field (Omnipose)",
              trainingData: "Cellpose cyto2 set, Omnipose-retrained",
              paper: "Cutler et al. — Omnipose (Nature Methods, 2022)",
              outputType: "Masks + boxes + outlines"),
    ]

    /// Classical threshold + watershed — no deep learning anywhere in the path.
    ///
    /// Zero weights, zero download, zero GPU, zero network. Runs in well under
    /// a second and is bit-for-bit deterministic, which makes it the right
    /// answer for three situations the neural detectors handle badly: a result
    /// that has to be exactly reproducible, a machine with no network or no
    /// GPU, and a sanity check when a learned model returns something
    /// implausible. It is also the cheapest possible second opinion — pair it
    /// with any Cellpose model in the Ensemble family.
    ///
    /// The only prerequisite is the base Python environment (scikit-image +
    /// scipy), which `install_python.sh` already provides, so there is no
    /// per-model install step. See `ClassicalDownloader`.
    static let classical: [DetectionModelInfo] = [
        .init(id: "cw-otsu", family: .classical, name: "Threshold + watershed (Otsu)",
              sizeMB: 0, sizeLabel: "no download",
              desc: "Otsu threshold, distance transform, watershed. Instant, deterministic, no GPU. Good default for well-separated cells.",
              state: .off, speed: .fast, accuracy: .med,
              tags: ["fluor", "bf", "phase"], builtIn: false,
              license: "BSD (scikit-image)",
              architecture: "Otsu threshold → distance transform → watershed",
              trainingData: "None — classical image processing",
              paper: "Otsu (1979); Beucher & Lantuéjoul watershed (1979)",
              outputType: "Masks + boxes + outlines"),
        .init(id: "cw-triangle", family: .classical, name: "Threshold + watershed (Triangle)",
              sizeMB: 0, sizeLabel: "no download",
              desc: "Triangle threshold instead of Otsu. Better when cells are sparse or faint and Otsu clips them.",
              state: .off, speed: .fast, accuracy: .med,
              tags: ["fluor"],
              license: "BSD (scikit-image)",
              architecture: "Triangle threshold → distance transform → watershed",
              trainingData: "None — classical image processing",
              paper: "Zack et al. — Triangle method (1977)",
              outputType: "Masks + boxes + outlines"),
        .init(id: "cw-adaptive", family: .classical, name: "Threshold + watershed (Adaptive)",
              sizeMB: 0, sizeLabel: "no download",
              desc: "Local threshold surface for uneven illumination or vignetting, where one global cutoff can't fit the whole field.",
              state: .off, speed: .fast, accuracy: .med,
              tags: ["bf", "phase"],
              license: "BSD (scikit-image)",
              architecture: "Local threshold → distance transform → watershed",
              trainingData: "None — classical image processing",
              paper: "Sauvola & Pietikäinen — local thresholding (2000)",
              outputType: "Masks + boxes + outlines"),
        .init(id: "cw-manual", family: .classical, name: "Threshold + watershed (Manual)",
              sizeMB: 0, sizeLabel: "no download",
              desc: "Fixed intensity cutoff you set yourself. Fully reproducible across images — set the value in Settings.",
              state: .off, speed: .fast, accuracy: .med,
              tags: ["fluor", "bf"],
              license: "BSD (scikit-image)",
              architecture: "Manual threshold → distance transform → watershed",
              trainingData: "None — classical image processing",
              paper: "—",
              outputType: "Masks + boxes + outlines"),
    ]

    /// Ensemble — "second opinion". Runs two detectors you pick on the same
    /// image, matches their masks, and drops the confidence of every cell they
    /// DISAGREE about into the review window so the Review queue surfaces
    /// exactly those. Agreement and disagreement counts land in `image_stats`.
    ///
    /// The point is triage: instead of reviewing 400 cells, review the 12 the
    /// two models could not agree on.
    static let ensemble: [DetectionModelInfo] = [
        .init(id: "ensemble-2", family: .ensemble, name: "Second opinion (2 models)",
              sizeMB: 0, sizeLabel: "no download",
              desc: "Runs two models you choose and flags only the cells they disagree about. Costs one extra detection pass.",
              state: .off, speed: .slow, accuracy: .high,
              tags: ["any"],
              license: "—",
              note: "Configure the pair in Models",
              architecture: "Two detectors + greedy nearest-neighbour mask matching",
              trainingData: "Inherited from the two member models",
              paper: "—",
              outputType: "Masks + boxes + agreement flags"),
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

    /// Every catalog entry, including the user's own registered models.
    ///
    /// `CustomModelStore.catalogEntries()` reads UserDefaults, so this is a
    /// computed property rather than a `let`: registering a bring-your-own
    /// model has to show up without an app restart. `AppState` re-reads this
    /// on `.ccCustomModelsChanged`.
    static var all: [DetectionModelInfo] {
        builtIn + cellpose + cellpose4 + stardist + sam
            + omnipose + classical + ensemble
            + CustomModelStore.catalogEntries()
    }

    /// The detector to fall back on when nothing else is available — no
    /// weights, no download, no GPU, no network. Callers that need *a* result
    /// (or a cheap second opinion) can resolve this id without checking
    /// anything first, because the classical family has no install step.
    static let classicalFallbackId = "cw-otsu"
}
