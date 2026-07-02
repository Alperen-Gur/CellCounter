import SwiftUI

/// Maps the design's lucide-ish icon names to SF Symbols (closest visual match).
/// We use SF Symbols at light/regular weight to approximate the 1.8 stroke width.
enum Icons {
    static func symbol(_ name: String) -> String {
        switch name {
        case "home":      return "house"
        case "queue":     return "list.bullet"
        case "library":   return "books.vertical"
        case "image":     return "photo"
        case "cpu":       return "cpu"
        case "sparkles":  return "sparkles"
        case "trash":     return "trash"
        case "settings":  return "gearshape"
        case "help":      return "questionmark.circle"
        case "plus":      return "plus"
        case "minus":     return "minus"
        case "x":         return "xmark"
        case "chevron":   return "chevron.down"
        case "chevronr":  return "chevron.right"
        case "search":    return "magnifyingglass"
        case "folder":    return "folder"
        case "folderup":  return "folder.badge.plus"
        case "file":      return "doc"
        case "download":  return "arrow.down.to.line"
        case "upload":    return "arrow.up.to.line"
        case "play":      return "play.fill"
        case "pause":     return "pause.fill"
        case "stop":      return "stop.fill"
        case "eye":       return "eye"
        case "eyeoff":    return "eye.slash"
        case "zoomin":    return "plus.magnifyingglass"
        case "zoomout":   return "minus.magnifyingglass"
        case "fit":       return "arrow.up.left.and.arrow.down.right"
        case "bbox":      return "rectangle.dashed"
        case "circle":    return "circle"
        case "ruler":     return "ruler"
        case "info":      return "info.circle"
        case "check":     return "checkmark"
        case "star":      return "star"
        case "arrow":     return "arrow.right"
        case "flask":     return "flask"
        case "table":     return "tablecells"
        case "layers":    return "square.stack.3d.up"
        case "cmd":       return "command"
        case "moon":      return "moon"
        case "compare":   return "chart.bar.fill"
        case "refresh":   return "arrow.clockwise"
        default:          return "circle"
        }
    }
}

/// Convenience view: `Icon("ruler")` or `Icon("ruler", size: 14)`
struct Icon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(systemName: Icons.symbol(name))
            .font(.system(size: size, weight: .regular))
            .frame(width: size, height: size)
    }
}
