import SwiftUI

// MARK: - KeyboardShortcutsSheet
//
// Lists every keyboard shortcut grouped by screen.
// Visual language matches CalibrationSheet: backdrop + centered card, header/body/footer,
// soft drop-in animation. Opened via Help → "Keyboard Shortcuts" (⌘/) or the menu.

struct KeyboardShortcutsSheet: View {
    let onClose: () -> Void

    @State private var appeared = false
    @Environment(AppTheme.self) private var theme

    var body: some View {
        ZStack {
            Tokens.bgOverlay
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keyboard Shortcuts")
                            .font(.system(size: 18, weight: .bold))
                            .tracking(-0.01 * 18)
                            .foregroundStyle(Tokens.text)
                        Text("Per-screen shortcuts — active only in the corresponding view.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Icon("x", size: 14)
                            .foregroundStyle(Tokens.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(Tokens.bgSunken))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                // Body — scrollable groups
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ShortcutGroup(title: "Global", rows: [
                            ("⌘O",        "Open images…"),
                            ("⌘⇧O",       "Open folder…"),
                            ("⌘,",        "Settings"),
                            ("⌘.",        "Cancel current sheet"),
                            ("⌘/",        "Keyboard shortcuts (this sheet)"),
                        ])
                        ShortcutGroup(title: "Home", rows: [
                            ("⌘D",        "Choose images… (primary CTA)"),
                            ("⌘⇧D",       "Choose folder…"),
                        ])
                        ShortcutGroup(title: "Results", rows: [
                            ("Space",      "Toggle overlay (master fills + outlines)"),
                            ("X",          "Toggle filled masks only"),
                            ("Z",          "Toggle outline strokes only"),
                            ("⌘+  /  ⌘=", "Zoom in"),
                            ("⌘-",        "Zoom out"),
                            ("⌘0",        "Fit to view"),
                            ("⌘1",        "Box overlay mode"),
                            ("⌘2",        "Outline overlay mode"),
                            ("←  /  →",   "Previous / Next image in batch"),
                            ("⌘E",        "Export annotated PNG"),
                            ("⌘⇧E",       "Export PNG + CSV"),
                            ("⌘R",        "Re-run detection on current image"),
                            ("V",         "Cell-edit mode: View"),
                            ("A",         "Cell-edit mode: Add"),
                            ("R",         "Cell-edit mode: Remove"),
                            ("M",         "Cell-edit mode: Merge"),
                            ("C",         "Cell-edit mode: Manual count"),
                            ("Delete",    "Remove selected cell"),
                            ("Esc",       "Exit edit mode → View, clear selection"),
                            ("⌘Z",        "Undo"),
                            ("⌘⇧Z / ⌘Y", "Redo"),
                        ])
                        ShortcutGroup(title: "Batches", rows: [
                            ("Delete",    "Delete current batch (confirm)"),
                            ("⌘E",        "Export per-image summary CSV"),
                        ])
                        ShortcutGroup(title: "Images Library", rows: [
                            ("Delete",    "Delete selected image (confirm)"),
                            ("Return",    "Open in Results"),
                            ("⌘A",        "Select all"),
                        ])
                        ShortcutGroup(title: "Models", rows: [
                            ("⌘F",        "Focus search field"),
                        ])
                        ShortcutGroup(title: "Review Queue", rows: [
                            ("R",         "Reject"),
                            ("K",         "Keep"),
                            ("E",         "Edit diameter"),
                            ("→",         "Next without action"),
                            ("Esc",       "Exit review queue → Home"),
                        ])
                        ShortcutGroup(title: "Fine-tune", rows: [
                            ("⌘←",        "Previous step"),
                            ("⌘→",        "Next step"),
                            ("Space",     "Pause / resume training (Step 4 only)"),
                        ])
                        ShortcutGroup(title: "Calibration Sheet", rows: [
                            ("Return",    "Save (when valid)"),
                            ("Esc",       "Cancel"),
                        ])
                        ShortcutGroup(title: "Onboarding Sheet", rows: [
                            ("Return",    "Next / Get started"),
                            ("Esc",       "Skip onboarding"),
                        ])
                        ShortcutGroup(title: "Install Sheet", rows: [
                            ("Return",    "Install / Retry"),
                            ("Esc",       "Close (when not installing)"),
                        ])
                        ShortcutGroup(title: "Compare", rows: [
                            ("⌘E",        "Export comparison CSV"),
                        ])
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                .frame(maxHeight: 520)

                // Footer
                HStack {
                    Spacer()
                    Button("Close", action: onClose)
                        .appButton(.primary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Tokens.bgSunken)
                .overlay(Divider().frame(maxWidth: .infinity, maxHeight: 0.5), alignment: .top)
            }
            .frame(width: 600)
            .background(Tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 60, y: 24)
            .offset(y: appeared ? 0 : -12)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.98)
        }
        .onAppear {
            withAnimation(Tokens.Motion.easeSlow) { appeared = true }
        }
        .onKeyPress(.escape) { onClose(); return .handled }
    }
}

// MARK: — Shortcut Group

private struct ShortcutGroup: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.06 * 10.5)
                .foregroundStyle(Tokens.textTertiary)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    HStack(spacing: 12) {
                        Text(row.0)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Tokens.text)
                            .frame(minWidth: 100, alignment: .trailing)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Tokens.bgSunken)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                            )

                        Text(row.1)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Tokens.textSecondary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Tokens.bgElevated)
                    .overlay(alignment: .top) {
                        if idx > 0 {
                            Rectangle().fill(Tokens.divider).frame(height: 0.5)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
        }
    }
}
