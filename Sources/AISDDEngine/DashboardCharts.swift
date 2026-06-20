public enum DashboardCharts {
    public static let defaultColors: [DashboardStatus: String] = [
        .done: "#2e7d32",
        .inProgress: "#1565c0",
        .rework: "#f9a825",
        .escalated: "#c62828",
        .runnable: "#616161",
        .pending: "#9e9e9e"
    ]

    public static func statusDonut(_ summary: DashboardProjectionSummary,
                                   colors: [DashboardStatus: String] = defaultColors) -> String {
        let total = DashboardStatus.allCases.reduce(0) { $0 + max(0, summary.statusTotals[$1, default: 0]) }
        let pathLength = max(total, 1)
        let label = "Status distribution: " + DashboardStatus.allCases
            .map { "\($0.rawValue) \(max(0, summary.statusTotals[$0, default: 0]))" }
            .joined(separator: ", ")

        var lines = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 220\" role=\"img\" aria-label=\"\(escape(label))\" class=\"dashboard-chart dashboard-status-donut\">",
            "  <g transform=\"translate(78 72) rotate(-90)\">",
            "    <circle cx=\"0\" cy=\"0\" r=\"48\" fill=\"none\" stroke=\"#eceff1\" stroke-width=\"18\"/>"
        ]
        var offset = 0
        for status in DashboardStatus.allCases {
            let count = max(0, summary.statusTotals[status, default: 0])
            lines.append(
                "    <circle class=\"status-segment status-\(escape(status.rawValue))\" data-status=\"\(escape(status.rawValue))\" data-count=\"\(count)\" cx=\"0\" cy=\"0\" r=\"48\" fill=\"none\" stroke=\"\(escape(color(for: status, colors: colors)))\" stroke-width=\"18\" pathLength=\"\(pathLength)\" stroke-dasharray=\"\(count) \(max(pathLength - count, 0))\" stroke-dashoffset=\"-\(offset)\"><title>\(escape(status.rawValue)): \(count)</title></circle>"
            )
            offset += count
        }
        lines += [
            "  </g>",
            "  <text x=\"78\" y=\"77\" text-anchor=\"middle\" class=\"chart-total\">\(total)</text>",
            "  <g class=\"chart-legend\">"
        ]
        for (index, status) in DashboardStatus.allCases.enumerated() {
            let y = 20 + index * 26
            let count = max(0, summary.statusTotals[status, default: 0])
            lines.append("    <rect x=\"160\" y=\"\(y - 10)\" width=\"12\" height=\"12\" fill=\"\(escape(color(for: status, colors: colors)))\"/>")
            lines.append("    <text x=\"180\" y=\"\(y)\" class=\"legend-label\">\(escape(status.rawValue)) \(count)</text>")
        }
        lines += [
            "  </g>",
            "</svg>"
        ]
        return lines.joined(separator: "\n")
    }

    public static func groupedBarChart(_ rows: [DashboardProjectionRow],
                                       colors: [DashboardStatus: String] = defaultColors) -> String {
        let groups = grouped(rows)
        let maxTotal = max(groups.map(\.total).max() ?? 0, 1)
        let rowHeight = 36
        let top = 32
        let chartWidth = 180
        let height = max(110, top + groups.count * rowHeight + 28)
        let label = "Status by owner: " + groups
            .map { "\($0.label) \($0.total)" }
            .joined(separator: ", ")

        var lines = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 420 \(height)\" role=\"img\" aria-label=\"\(escape(label))\" class=\"dashboard-chart dashboard-grouped-bars\">",
            "  <g class=\"bar-groups\">"
        ]
        for (index, group) in groups.enumerated() {
            let y = top + index * rowHeight
            lines.append("    <g class=\"bar-group\" data-group=\"\(escape(group.label))\" data-total=\"\(group.total)\">")
            lines.append("      <text x=\"0\" y=\"\(y + 13)\" class=\"group-label\">\(escape(group.label))</text>")
            lines.append("      <rect x=\"150\" y=\"\(y)\" width=\"\(chartWidth)\" height=\"16\" fill=\"#eceff1\"/>")
            var x = 150
            var allocated = 0
            for status in DashboardStatus.allCases {
                let count = group.counts[status, default: 0]
                let width: Int
                if status == DashboardStatus.allCases.last {
                    width = max(0, scaledWidth(group.total, maxTotal: maxTotal, chartWidth: chartWidth) - allocated)
                } else {
                    width = count == 0 ? 0 : Int((Double(count) / Double(maxTotal) * Double(chartWidth)).rounded())
                    allocated += width
                }
                lines.append("      <rect class=\"status-bar status-\(escape(status.rawValue))\" data-status=\"\(escape(status.rawValue))\" data-count=\"\(count)\" x=\"\(x)\" y=\"\(y)\" width=\"\(width)\" height=\"16\" fill=\"\(escape(color(for: status, colors: colors)))\"><title>\(escape(group.label)) \(escape(status.rawValue)): \(count)</title></rect>")
                x += width
            }
            lines.append("      <text x=\"342\" y=\"\(y + 13)\" class=\"group-total\">\(group.total)</text>")
            lines.append("    </g>")
        }
        if groups.isEmpty {
            lines.append("    <text x=\"0\" y=\"32\" class=\"empty-label\">No dashboard rows</text>")
        }
        lines += [
            "  </g>",
            "</svg>"
        ]
        return lines.joined(separator: "\n")
    }

    private struct Group {
        var label: String
        var counts: [DashboardStatus: Int]
        var total: Int
    }

    private static func grouped(_ rows: [DashboardProjectionRow]) -> [Group] {
        var countsByLabel: [String: [DashboardStatus: Int]] = [:]
        for row in rows {
            countsByLabel[row.owner, default: initializedCounts()][row.status, default: 0] += 1
        }
        return countsByLabel.keys.sorted().map { label in
            let counts = countsByLabel[label, default: initializedCounts()]
            let total = DashboardStatus.allCases.reduce(0) { $0 + counts[$1, default: 0] }
            return Group(label: label, counts: counts, total: total)
        }
    }

    private static func initializedCounts() -> [DashboardStatus: Int] {
        Dictionary(uniqueKeysWithValues: DashboardStatus.allCases.map { ($0, 0) })
    }

    private static func scaledWidth(_ count: Int, maxTotal: Int, chartWidth: Int) -> Int {
        count == 0 ? 0 : Int((Double(count) / Double(maxTotal) * Double(chartWidth)).rounded())
    }

    private static func color(for status: DashboardStatus, colors: [DashboardStatus: String]) -> String {
        colors[status] ?? defaultColors[status] ?? "#9e9e9e"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
