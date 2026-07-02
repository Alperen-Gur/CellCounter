import SwiftUI

// MARK: — Buttons

enum AppButtonVariant {
    case standard, primary, ghost, danger
}

struct AppButtonStyle: ButtonStyle {
    var variant: AppButtonVariant = .standard
    var size: Size = .md
    enum Size { case sm, md, lg }

    @Environment(\.colorScheme) private var scheme
    @Environment(AppTheme.self) private var theme

    private var paddingH: CGFloat { size == .sm ? 8 : size == .lg ? 18 : 11 }
    private var paddingV: CGFloat { size == .sm ? 3 : size == .lg ? 9  : 5 }
    private var font: Font {
        switch size {
        case .sm: return .system(size: 11.5, weight: .medium)
        case .md: return .system(size: 12.5, weight: .medium)
        case .lg: return .system(size: 13,   weight: .medium)
        }
    }
    private var radius: CGFloat {
        size == .lg ? Tokens.Radius.lg : Tokens.Radius.md
    }

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color
        let fg: Color
        let borderColor: Color
        let shadow: Color
        switch variant {
        case .standard:
            bg = Tokens.bgElevated
            fg = Tokens.text
            borderColor = Tokens.borderStrong
            shadow = Color.black.opacity(0.06)
        case .primary:
            bg = theme.accentColor
            fg = .white
            borderColor = .clear
            shadow = Color.black.opacity(0.10)
        case .ghost:
            bg = .clear
            fg = Tokens.textSecondary
            borderColor = .clear
            shadow = .clear
        case .danger:
            bg = Tokens.bgElevated
            fg = Tokens.danger
            borderColor = Tokens.borderStrong
            shadow = Color.black.opacity(0.06)
        }
        return configuration.label
            .font(font)
            .foregroundStyle(fg)
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed && variant == .standard ? Tokens.hover : bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .shadow(color: shadow, radius: variant == .ghost ? 0 : 1.2, y: 0.7)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func appButton(_ variant: AppButtonVariant = .standard, size: AppButtonStyle.Size = .md) -> some View {
        self.buttonStyle(AppButtonStyle(variant: variant, size: size))
    }
}

// MARK: — Chip

struct Chip: View {
    let title: String
    var active: Bool = false
    var dot: Color? = nil
    var action: () -> Void

    @Environment(AppTheme.self) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(active ? theme.accentSoft : Tokens.bgSunken)
            )
            .overlay(
                Capsule().strokeBorder(active ? Color.clear : Tokens.border, lineWidth: 0.5)
            )
            .foregroundStyle(active ? theme.accentColor : Tokens.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: — Toggle / Switch (custom to match macOS-design)

struct CustomToggle: View {
    @Binding var isOn: Bool
    @Environment(AppTheme.self) private var theme

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? theme.accentColor : Tokens.borderStrong)
                .frame(width: 36, height: 21)
            Circle()
                .fill(.white)
                .frame(width: 17, height: 17)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .padding(2)
        }
        .animation(.easeOut(duration: 0.14), value: isOn)
        .onTapGesture { isOn.toggle() }
    }
}

// MARK: — Segmented control

struct SegmentedPicker<Value: Hashable>: View {
    @Binding var value: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                Button { value = opt.value } label: {
                    Text(opt.label)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .foregroundStyle(value == opt.value ? Tokens.text : Tokens.textSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: 4).fill(
                                value == opt.value ? Tokens.bgElevated : .clear
                            )
                            .shadow(color: value == opt.value ? .black.opacity(0.06) : .clear,
                                    radius: 1.2, y: 0.7)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgSunken))
    }
}

// MARK: — Pill (toolbar model selector)

struct ToolbarPill: View {
    let label: String
    let value: String
    var trailingChevron: Bool = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(label.uppercased())
                        .tracking(0.04 * 11)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Tokens.textTertiary)
                    Text(value)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                }
                if trailingChevron {
                    Icon("chevron", size: 12)
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.bgSunken))
                }
            }
            .padding(.leading, 10).padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(Tokens.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: — Section header

struct SectionHeader: View {
    let title: String
    var action: (label: String, handler: () -> Void)? = nil
    var trailing: AnyView? = nil

    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .tracking(0.04 * 13)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            if let action {
                Button(action: action.handler) {
                    Text(action.label)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
            if let trailing { trailing }
        }
        .padding(.bottom, 12)
    }
}

// MARK: — Tag (model-row pill-y label)

struct TagLabel: View {
    let text: String
    enum Style { case neutral, fast, acc, licNc, accent }
    var style: Style = .neutral

    @Environment(AppTheme.self) private var theme

    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch style {
            case .neutral: return (Tokens.bgSunken, Tokens.textTertiary)
            case .fast:    return (Color(OKLCH(0.55, 0.13, 155, alpha: 0.08)),
                                   Color(OKLCH(0.55, 0.13, 155)))
            case .acc:     return (Color(OKLCH(0.55, 0.12, 250, alpha: 0.08)),
                                   Color(OKLCH(0.55, 0.12, 250)))
            case .licNc:   return (Color(OKLCH(0.78, 0.14, 75, alpha: 0.12)), Tokens.warning)
            case .accent:  return (theme.accentSoft, theme.accentColor)
            }
        }()
        return Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
    }
}

// MARK: — Spinner

struct AppSpinner: View {
    @Environment(AppTheme.self) private var theme
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotating = true
                }
            }
    }
}

// MARK: — Status dot

struct StatusDot: View {
    let status: BatchRowStatus

    @Environment(AppTheme.self) private var theme
    @State private var pulse = false

    var body: some View {
        let color: Color = {
            switch status {
            case .done: return Tokens.success
            case .running: return theme.accentColor
            case .queued: return Tokens.textTertiary
            case .error: return Tokens.danger
            }
        }()
        Circle().fill(color)
            .frame(width: 8, height: 8)
            .opacity(status == .running && pulse ? 0.4 : 1)
            .onAppear {
                if status == .running {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            }
    }
}
