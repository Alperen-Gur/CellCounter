import Foundation
import SwiftUI

/// Reverts a custom (fine-tuned) model's active checkpoint to a chosen prior
/// `ModelVersionRecord`. Surfaces the swap via:
///   1. `AppState.models` — ensures the entry exists / its `desc` reflects the version.
///   2. `UserDefaults("cc-rollback-<modelId>")` — small string marker ("v3") so the
///      detector can pick up the chosen checkpoint after a relaunch even if the
///      DetectionService isn't refreshed live.
///   3. `state.activate(modelId)` — flips it to the active model so Results uses it.
///
/// The actual detector swap is owned by `AppState` (see `refreshDetector` once it
/// lands from S2). Until then, the marker key drives the choice at next launch.
enum RollbackService {
    @MainActor
    static func rollback(to version: ModelVersionRecord, in state: AppState) {
        let modelId = version.modelId

        // 1) Find or synthesize a DetectionModelInfo for this id.
        if let idx = state.models.firstIndex(where: { $0.id == modelId }) {
            // Reflect the rolled-back version in the visible description.
            let existing = state.models[idx]
            let rebuilt = DetectionModelInfo(
                id: existing.id,
                family: existing.family,
                name: existing.name,
                sizeMB: existing.sizeMB,
                sizeLabel: existing.sizeLabel,
                desc: "Rolled back to v\(version.version) · \(version.trainedOnImages) images · \(version.trainedOnCorrections) corrections",
                state: existing.state,
                speed: existing.speed,
                accuracy: existing.accuracy,
                tags: existing.tags,
                builtIn: existing.builtIn,
                recommended: existing.recommended,
                custom: existing.custom,
                license: existing.license,
                note: existing.note,
                architecture: existing.architecture,
                trainingData: existing.trainingData,
                paper: existing.paper,
                outputType: existing.outputType
            )
            state.models[idx] = rebuilt
        } else {
            // Custom model isn't currently in the catalog (e.g. older fine-tune).
            // Append a minimal entry so the user can see + activate it.
            let synthesized = DetectionModelInfo(
                id: modelId,
                family: .custom,
                name: "Custom model",
                sizeMB: 28,
                sizeLabel: "28 MB",
                desc: "Rolled back to v\(version.version) · \(version.trainedOnImages) images · \(version.trainedOnCorrections) corrections",
                state: .downloaded,
                speed: .fast,
                accuracy: .high,
                tags: ["custom"],
                custom: true,
                architecture: "Fine-tuned (from prior checkpoint)",
                trainingData: "User library",
                paper: "User fine-tune",
                outputType: "Masks + boxes + outlines"
            )
            state.models.append(synthesized)
        }

        // 2) Persist the rollback marker — survives relaunch even if the in-memory
        //    detector isn't refreshed during this session.
        UserDefaults.standard.set("v\(version.version)", forKey: "cc-rollback-\(modelId)")

        // 3) Activate the rolled-back model.
        state.activate(modelId)

        // 4) Refresh detector so the live DetectionService picks up the new checkpoint.
        state.refreshDetector()
    }
}
