import SwiftUI

struct QueueEmpty: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Tokens.textQuaternary.opacity(0.7))
                .padding(.bottom, 4)
            Text("Queue is empty")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("Active analyses appear here. Drop a folder to fill it up.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Back to Home") { state.view = .home }
                .appButton(.primary, size: .sm)
                .padding(.top, 4)
        }
        .padding(.vertical, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Tokens.textQuaternary.opacity(0.7))
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
