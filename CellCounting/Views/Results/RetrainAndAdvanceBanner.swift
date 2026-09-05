import SwiftUI
import Combine

/// Reviewed masks enter the same validated dataset/split workflow as the full
/// training screen. A single correction never silently approves an entire field.
struct RetrainAndAdvanceBanner: View {
    @Bindable var state: AppState
    @ObservedObject var controller: RetrainAndAdvanceController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Train from your corrected masks", systemImage: "sparkles")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Review complete fields and assign independent specimens to training, validation, and test sets. Activate the checkpoint after evaluating it.")
                .font(.system(size: 11.5)).foregroundStyle(Tokens.textSecondary)
            Button("Review training dataset") { controller.start(state: state) }
                .appButton(.primary, size: .sm)
        }.padding(12).background(Tokens.bgSunken)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
    }
}

@MainActor final class RetrainAndAdvanceController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusLine = ""
    func start(state: AppState) { state.view = .fineTune }
}
