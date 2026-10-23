import SwiftUI

struct NavItemView: View {
    let icon: String
    let label: String
    var count: Int? = nil
    let isActive: Bool
    let action: () -> Void

    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(icon, size: 16)
                    .foregroundStyle(isActive ? theme.accentColor : Tokens.textSecondary)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? theme.accentColor : Tokens.text)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(isActive
                          ? theme.accentSoftAdaptive(for: scheme)
                          : (hovered ? Tokens.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Tokens.Motion.easeFast, value: hovered)
    }
}

struct SidebarSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .tracking(0.04 * 10.5)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Tokens.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 12).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppSidebar: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme
    @State private var showingSupport = false

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    AppMark(size: 22)
                    Text("CellCounter")
                        .font(.system(size: 13.5, weight: .bold))
                        .tracking(-0.01 * 13.5)
                }
                .padding(.horizontal, 10).padding(.bottom, 14).padding(.top, 2)

                SidebarSectionLabel(text: "Microscopy")
                NavItemView(icon: "workspace", label: "Workbench", isActive: state.view == .workbench) {
                    state.view = .workbench
                }
                if state.view == .workbench, state.workbenchSession.hasProject {
                    Text(state.workbenchSession.projectName)
                        .font(.caption).foregroundStyle(Tokens.textSecondary)
                        .lineLimit(2).padding(.horizontal, 10).padding(.vertical, 6)
                }

                SidebarSectionLabel(text: "Existing data")
                Menu {
                    Text("Existing library — compatibility tools")
                    Button("Library overview") { state.view = .home }
                    Button("Images") { state.view = .imagesLibrary }
                    Button("Batches") { state.view = .batch }
                    Button("Review queue") { state.view = .reviewQueue }
                    Button("Compare conditions") { state.view = .compare }
                    Button("Processing jobs (\(state.jobScheduler.activeCount) active)") { state.view = .queue }
                    Divider()
                    Button("Models and installation") { state.view = .models }
                    Button("Fine-tuning") { state.view = .fineTune }
                    Button("Inspect or export workspace") { state.view = .workspace }
                    Divider()
                    Button("Copy library data into a project…") { state.prepareLibraryMigration() }
                        .disabled(state.preparingLibraryMigration || state.jobScheduler.activeCount > 0 || TrainingService.isTrainingActive)
                } label: {
                    HStack(spacing: 10) {
                        Icon("library", size: 16)
                        Text("Existing library").font(.system(size: 13))
                        Spacer(minLength: 0)
                        if state.jobScheduler.activeCount > 0 {
                            Text("\(state.jobScheduler.activeCount)").font(.caption.monospacedDigit())
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .menuStyle(.borderlessButton)
                .help("Review existing library data and jobs, or copy them into a microscopy project.")

                Spacer()

                VStack(alignment: .leading, spacing: 1) {
                    NavItemView(icon: "help",     label: "Support",  isActive: false) { showingSupport = true }
                    NavItemView(icon: "settings", label: "Settings", isActive: state.view == .settings) { state.view = .settings }
                }
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
            }
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 12)
            .frame(width: 220)
            .background(Tokens.bgSidebar)
            .background(.regularMaterial.opacity(0.4))
            .overlay(alignment: .trailing) { Rectangle().fill(Tokens.border).frame(width: 0.5) }

            if showingSupport {
                SupportSheet(state: state) { showingSupport = false }
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .overlay(alignment: .bottom) { LocalTimingIndicator() }
        .animation(Tokens.Motion.easeFast, value: showingSupport)
    }
}

struct AppMark: View {
    var size: CGFloat = 22
    @Environment(AppTheme.self) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(theme.accentSoft)
            Canvas { ctx, sz in
                let s = min(sz.width, sz.height)
                let center = CGPoint(x: sz.width/2, y: sz.height/2)
                // outer ring
                let ringPath = Path(ellipseIn: CGRect(
                    x: center.x - s * 0.40, y: center.y - s * 0.40,
                    width: s * 0.80, height: s * 0.80))
                ctx.stroke(ringPath, with: .color(theme.accentColor), lineWidth: 1.8)
                // dots
                let dots: [(CGFloat, CGFloat, CGFloat, Double)] = [
                    (-s*0.12, -s*0.08, s*0.075, 1.0),
                    ( s*0.13, -s*0.13, s*0.05,  0.7),
                    ( s*0.02,  s*0.10, s*0.065, 0.85)
                ]
                for (dx, dy, r, op) in dots {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: center.x + dx - r, y: center.y + dy - r,
                                               width: r*2, height: r*2)),
                        with: .color(theme.accentColor.opacity(op)))
                }
            }
        }
        .frame(width: size, height: size)
    }
}
