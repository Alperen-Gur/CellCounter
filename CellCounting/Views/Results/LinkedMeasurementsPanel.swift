import SwiftUI
import AppKit

/// Linked views use the same selection binding as the image overlay. Rows are
/// paged; the scatter uses a bounded display sample but brushing queries every
/// measured cell, so dense outliers are never silently omitted from selection.
struct LinkedMeasurementsPanel: View {
    let cells: [DetectedCell]
    let revision: ReviewDataKey?
    @Binding var selectedCellIds: Set<UUID>
    @State private var plot = MeasurementPlot(cells: [])
    @State private var displayPoints: [MeasurementPoint] = []
    @State private var selectedPoints: [MeasurementPoint] = []
    @State private var channels: [ChannelIntensity] = []
    @State private var channel = -1
    @State private var page = 0
    @State private var selectedOnly = false
    @State private var rows: [DetectedCell] = []
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    private let pageSize = 40
    private let plotLimit = 4000

    private var pageCount: Int { max(1, (rows.count + pageSize - 1) / pageSize) }
    private var pageRows: ArraySlice<DetectedCell> {
        let start = min(rows.count, page * pageSize)
        return rows[start..<min(rows.count, start + pageSize)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Linked cell measurements")
            Text("Select a row or point to highlight its cell. Drag a box to select outliers; Shift adds to selection.")
                .font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !channels.isEmpty {
                Picker("Intensity", selection: $channel) {
                    Text("Detection plane").tag(-1)
                    ForEach(channels, id: \.channel) { entry in Text(entry.displayName).tag(entry.channel) }
                }.font(.system(size: 11))
            }
            if plot.points.isEmpty {
                Text("Area and intensity measurements are unavailable for these cells.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.textTertiary)
                    .padding(.vertical, 12)
            } else {
                HStack {
                    Text("Area \(format(plot.areaRange.lowerBound))–\(format(plot.areaRange.upperBound)) µm²")
                    Spacer()
                    Text("Intensity \(format(plot.intensityRange.lowerBound))–\(format(plot.intensityRange.upperBound))")
                }.font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Tokens.textTertiary)
                scatter
                Text(channel < 0 ? "Area (µm²) × mean intensity (detection plane)" : "Area (µm²) × mean intensity (source units)")
                    .font(.system(size: 9.5)).foregroundStyle(Tokens.textTertiary)
                if plot.points.count > plotLimit {
                    Text("Showing \(plotLimit.formatted()) of \(plot.points.count.formatted()) points; box selection includes all measured cells.")
                        .font(.system(size: 9.5)).foregroundStyle(Tokens.textTertiary)
                }
            }
            HStack {
                Text("\(selectedCellIds.count.formatted()) selected")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("Clear") { selectedCellIds.removeAll() }
                    .buttonStyle(.plain).disabled(selectedCellIds.isEmpty)
            }
            Toggle("Show selected rows only", isOn: $selectedOnly)
                .font(.system(size: 10.5)).toggleStyle(.checkbox)
            measurementTable
            if !rows.isEmpty {
                HStack {
                    Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0)
                    Spacer()
                    Text("\(page * pageSize + 1)–\(min(rows.count, (page + 1) * pageSize)) of \(rows.count.formatted())")
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    Button { page = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(page >= pageCount - 1)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .task(id: revision) { rebuild() }
        .onChange(of: channel) { rebuildPlot() }
        .onChange(of: selectedOnly) { updateRows(); page = 0 }
        .onChange(of: selectedCellIds) { _, selection in
            selectedPoints = plot.points.filter { selection.contains($0.id) }
            updateRows()
            if !selectedOnly, let id = selection.count == 1 ? selection.first : nil,
               let index = rows.firstIndex(where: { $0.id == id }) { page = index / pageSize }
        }
    }

    private var scatter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for point in displayPoints {
                        let p = plot.position(point, size: size)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 1.7, y: p.y - 1.7, width: 3.4, height: 3.4)),
                                     with: .color(Color.accentColor.opacity(0.5)))
                    }
                    for point in selectedPoints.prefix(plotLimit) {
                        let p = plot.position(point, size: size)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                     with: .color(.orange))
                        context.stroke(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                       with: .color(.primary), lineWidth: 0.7)
                    }
                }
                if let start = dragStart, let end = dragEnd {
                    let rect = selectionRect(start, end)
                    Rectangle().fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .background(Tokens.bgSunken)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragStart = value.startLocation; dragEnd = value.location }
                .onEnded { value in
                    let rect = selectionRect(value.startLocation, value.location)
                    let ids: Set<UUID>
                    if rect.width < 4 && rect.height < 4 {
                        ids = plot.nearest(to: value.location, size: geometry.size).map { [$0] } ?? []
                    } else { ids = plot.selected(in: rect, size: geometry.size) }
                    selectedCellIds = MeasurementSelection.selecting(ids, from: selectedCellIds,
                                                                    extend: NSEvent.modifierFlags.contains(.shift))
                    dragStart = nil; dragEnd = nil
                })
            .accessibilityLabel("Cell area versus intensity scatter plot")
            .accessibilityHint("Use the measurement rows below to select individual cells with the keyboard.")
        }.frame(height: 170)
    }

    private var measurementTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cell").frame(width: 48, alignment: .leading)
                Text("Area µm²").frame(maxWidth: .infinity, alignment: .trailing)
                Text("Intensity").frame(width: 72, alignment: .trailing)
                Text("Conf.").frame(width: 40, alignment: .trailing)
            }.font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokens.textTertiary)
                .padding(.horizontal, 5).padding(.vertical, 6)
            ForEach(pageRows) { cell in
                Button {
                    if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
                        if selectedCellIds.contains(cell.id) { selectedCellIds.remove(cell.id) }
                        else { selectedCellIds.insert(cell.id) }
                    } else { selectedCellIds = [cell.id] }
                } label: {
                    HStack {
                        Text(cell.id.uuidString.prefix(6)).frame(width: 48, alignment: .leading)
                        Text(format(cell.areaMicrons2)).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(format(channel < 0 ? cell.meanIntensity : cell.channelIntensity(channel)?.mean))
                            .frame(width: 72, alignment: .trailing)
                        Text(String(format: "%.2f", cell.confidence)).frame(width: 40, alignment: .trailing)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(selectedCellIds.contains(cell.id) ? Color.accentColor : Tokens.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 5)
                    .background(selectedCellIds.contains(cell.id) ? Color.accentColor.opacity(0.13) : Color.clear)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Cell \(cell.id.uuidString.prefix(6)), area \(format(cell.areaMicrons2)), intensity \(format(channel < 0 ? cell.meanIntensity : cell.channelIntensity(channel)?.mean))")
            }
            if rows.isEmpty { Text(selectedOnly ? "No cells selected" : "No included cells")
                    .font(.system(size: 11)).foregroundStyle(Tokens.textTertiary).padding(12) }
        }
    }

    private func rebuild() {
        let entries = cells.first { $0.hasChannelIntensities }?.channelIntensities ?? []
        channels = entries.sorted { $0.channel < $1.channel }
        if channel >= 0 && !channels.contains(where: { $0.channel == channel }) { channel = -1 }
        rebuildPlot(); updateRows()
    }

    private func rebuildPlot() {
        plot = MeasurementPlot(cells: cells, channel: channel < 0 ? nil : channel)
        let count = plot.points.count
        if count <= plotLimit { displayPoints = plot.points }
        else { displayPoints = (0..<plotLimit).map { plot.points[$0 * count / plotLimit] } }
        selectedPoints = plot.points.filter { selectedCellIds.contains($0.id) }
    }

    private func updateRows() {
        rows = selectedOnly ? cells.filter { selectedCellIds.contains($0.id) } : cells
        page = min(page, pageCount - 1)
    }

    private func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    private func selectionRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
