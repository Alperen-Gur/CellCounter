import Foundation

/// A model the user brought themselves — a Cellpose checkpoint they fine-tuned
/// in another tool, or a StarDist model directory they trained elsewhere.
///
/// This is the piece that turns CellCounter into a front end for work a lab has
/// already done, rather than a closed set of four vendored architectures.
struct CustomModelEntry: Codable, Identifiable, Hashable {
    /// Which framework loads this model. Determines both the sidecar branch
    /// (`--custom-kind`) and what "a valid path" means.
    enum Kind: String, Codable, CaseIterable {
        /// A Cellpose checkpoint FILE, loaded with `CellposeModel(pretrained_model:)`.
        case cellpose
        /// A StarDist model DIRECTORY, loaded with `StarDist2D(None, name:, basedir:)`.
        case stardist

        var displayName: String {
            switch self {
            case .cellpose: return "Cellpose checkpoint"
            case .stardist: return "StarDist model folder"
            }
        }

        /// Cellpose models are a single file; StarDist models are a folder.
        var wantsDirectory: Bool { self == .stardist }
    }

    /// Which Python environment runs it. A checkpoint fine-tuned from Cellpose
    /// 3.x will not load under `cellpose>=4` and vice-versa, so the user tells
    /// us which one at registration time instead of us guessing and producing a
    /// confusing framework error at detection time.
    enum Runtime: String, Codable {
        /// The shared `venv/` — Cellpose 3.x and StarDist both live here.
        case base
        /// The isolated `venv4/` — Cellpose 4.x / CPSAM checkpoints.
        case cellpose4

        var displayName: String {
            switch self {
            case .base:      return "Cellpose 3.x / StarDist environment"
            case .cellpose4: return "Cellpose-SAM (4.x) environment"
            }
        }
    }

    /// Catalog id. Always prefixed `custom-` so it can never collide with a
    /// built-in id, and so `CustomModelDownloader` can recognise its own ids.
    let id: String
    var name: String
    /// Absolute path to the checkpoint file (cellpose) or model dir (stardist).
    var path: String
    var kind: Kind
    var runtime: Runtime
    var addedAt: Date

    init(id: String = "custom-\(UUID().uuidString.prefix(8).lowercased())",
         name: String,
         path: String,
         kind: Kind,
         runtime: Runtime = .base,
         addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.runtime = runtime
        self.addedAt = addedAt
    }

    var url: URL { URL(fileURLWithPath: path) }
}

/// Why a chosen path was rejected. Every case carries a message the user can
/// actually act on — "pick the folder, not the file inside it" beats
/// "invalid model".
enum CustomModelValidationError: LocalizedError, Equatable {
    case missing(path: String)
    case expectedFileGotDirectory(path: String)
    case expectedDirectoryGotFile(path: String)
    case tooSmall(path: String, bytes: Int)
    case missingStarDistConfig(path: String)
    case missingStarDistWeights(path: String)
    case unreadable(path: String)

    var errorDescription: String? {
        switch self {
        case .missing(let p):
            return "Nothing exists at \(p)."
        case .expectedFileGotDirectory(let p):
            return "\(URL(fileURLWithPath: p).lastPathComponent) is a folder. "
                 + "A Cellpose model is a single checkpoint file — pick the file inside the folder."
        case .expectedDirectoryGotFile(let p):
            return "\(URL(fileURLWithPath: p).lastPathComponent) is a file. "
                 + "A StarDist model is the folder that contains config.json — pick the folder."
        case .tooSmall(let p, let bytes):
            return "\(URL(fileURLWithPath: p).lastPathComponent) is only \(bytes) bytes, "
                 + "which is too small to be a Cellpose checkpoint."
        case .missingStarDistConfig(let p):
            return "\(URL(fileURLWithPath: p).lastPathComponent) has no config.json, "
                 + "so it isn't a StarDist model folder."
        case .missingStarDistWeights(let p):
            return "\(URL(fileURLWithPath: p).lastPathComponent) has config.json but no weights file "
                 + "(weights_best.h5, weights_last.h5, or a .keras file)."
        case .unreadable(let p):
            return "Can't read \(p). Check the file permissions."
        }
    }
}

/// Persistence + validation for bring-your-own models.
///
/// Storage is a JSON blob in UserDefaults rather than SwiftData: the list is
/// tiny, it has to be readable from `ModelCatalog.all` (a nonisolated static
/// computed property, so it can't touch a `@MainActor` store), and it must
/// survive independently of the image library the user might reset.
enum CustomModelStore {
    static let defaultsKey = "cc-custom-models"

    /// Posted after any mutation. `AppState` observes it and re-reads
    /// `ModelCatalog.all` so a newly registered model appears without a
    /// restart.
    static let changedNotification = Notification.Name("ccCustomModelsChanged")

    /// StarDist writes one of these next to config.json. The exact name depends
    /// on how the model was saved, so we accept any of them (and fall back to
    /// "any .h5/.keras in the folder").
    static let starDistWeightNames = [
        "weights_best.h5", "weights_last.h5", "weights_now.h5", "weights.h5",
    ]

    // MARK: — Read

    static func all() -> [CustomModelEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([CustomModelEntry].self, from: data) else {
            NSLog("[CustomModelStore] stored custom models are unreadable; ignoring")
            return []
        }
        return decoded.sorted { $0.addedAt < $1.addedAt }
    }

    static func entry(for modelId: String) -> CustomModelEntry? {
        all().first { $0.id == modelId }
    }

    static func isCustomId(_ modelId: String) -> Bool {
        modelId.hasPrefix("custom-")
    }

    // MARK: — Write

    @discardableResult
    static func add(_ entry: CustomModelEntry) -> Bool {
        var current = all()
        // Re-registering the same path replaces the old entry rather than
        // silently accumulating duplicates in the Models list.
        if let idx = current.firstIndex(where: { $0.path == entry.path }) {
            current[idx] = entry
        } else {
            current.append(entry)
        }
        return persist(current)
    }

    @discardableResult
    static func remove(id: String) -> Bool {
        persist(all().filter { $0.id != id })
    }

    @discardableResult
    private static func persist(_ entries: [CustomModelEntry]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else {
            NSLog("[CustomModelStore] failed to encode custom models")
            return false
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        return true
    }

    // MARK: — Validation

    /// Check that `path` still looks like a real model of `kind`.
    ///
    /// Deliberately mirrored by `validate_path()` in `custom_detect.py`. The
    /// Swift copy gives the user an immediate answer in the picker; the Python
    /// copy catches a model that was moved or deleted after registration, when
    /// the picker is long gone. Neither is redundant.
    ///
    /// Throws `CustomModelValidationError` describing what's wrong; returns
    /// normally when the path is plausible.
    static func validate(path: String, kind: CustomModelEntry.Kind) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw CustomModelValidationError.missing(path: path)
        }

        switch kind {
        case .cellpose:
            if isDir.boolValue {
                throw CustomModelValidationError.expectedFileGotDirectory(path: path)
            }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int else {
                throw CustomModelValidationError.unreadable(path: path)
            }
            // A real Cellpose checkpoint is megabytes. Anything under 1 KB is a
            // stray text file or a broken download.
            if size < 1024 {
                throw CustomModelValidationError.tooSmall(path: path, bytes: size)
            }

        case .stardist:
            if !isDir.boolValue {
                throw CustomModelValidationError.expectedDirectoryGotFile(path: path)
            }
            let configURL = URL(fileURLWithPath: path).appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configURL.path) else {
                throw CustomModelValidationError.missingStarDistConfig(path: path)
            }
            let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            let hasNamedWeights = contents.contains { starDistWeightNames.contains($0) }
            let hasAnyWeights = contents.contains {
                $0.hasSuffix(".h5") || $0.hasSuffix(".keras")
            }
            if !hasNamedWeights && !hasAnyWeights {
                throw CustomModelValidationError.missingStarDistWeights(path: path)
            }
        }
    }

    /// Non-throwing convenience for view code that just wants a message.
    static func validationMessage(path: String, kind: CustomModelEntry.Kind) -> String? {
        do {
            try validate(path: path, kind: kind)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: — Catalog projection

    /// Turn the registered entries into `DetectionModelInfo` rows so they
    /// appear in the Models list next to the built-ins.
    static func catalogEntries() -> [DetectionModelInfo] {
        all().map { entry in
            let stillValid = (try? validate(path: entry.path, kind: entry.kind)) != nil
            let framework = entry.kind == .cellpose ? "Cellpose" : "StarDist"
            let desc: String
            if stillValid {
                desc = "Your \(framework) model · \(entry.url.lastPathComponent)"
            } else {
                // Surface the breakage in the row itself rather than waiting
                // for a detection run to fail.
                desc = "Your \(framework) model · FILE MISSING at \(entry.path)"
            }
            return DetectionModelInfo(
                id: entry.id,
                family: .custom,
                name: entry.name,
                sizeMB: 0,
                sizeLabel: "on disk",
                desc: desc,
                state: .off,
                speed: entry.kind == .cellpose ? .fast : .fast,
                accuracy: .high,
                tags: [framework.lowercased(), "yours"],
                custom: true,
                license: "yours",
                note: stillValid ? nil : "Path missing",
                architecture: "\(framework) (user-supplied checkpoint)",
                trainingData: "Your own — trained outside CellCounter",
                paper: "—",
                outputType: "Masks + boxes + outlines"
            )
        }
    }
}
