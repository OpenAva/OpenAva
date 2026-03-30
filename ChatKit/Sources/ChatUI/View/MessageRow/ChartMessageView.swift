//
//  ChartMessageView.swift
//  ChatUI
//
//  Renders chart segments extracted from markdown messages.
//

import Charts
import MarkdownView
import SwiftUI
import UIKit

final class ChartMessageView: MessageListRowView {
    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let hostingController = UIHostingController(rootView: AnyView(EmptyView()))

    private var spec: ChartSpec?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        themeDidUpdate()
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidUpdate() {
        titleLabel.textColor = theme.colors.body

        // Use a dedicated chart card surface to improve contrast and reduce gray fatigue.
        let chartCardBackground = UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 0.78)
            }
            return UIColor(red: 0.97, green: 0.98, blue: 0.995, alpha: 0.95)
        }
        cardView.backgroundColor = chartCardBackground
        cardView.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        updateChartRootView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spec = nil
        titleLabel.text = nil
        hostingController.rootView = AnyView(EmptyView())
    }

    func configure(with spec: ChartSpec) {
        self.spec = spec
        titleLabel.text = spec.title
        titleLabel.isHidden = (spec.title ?? "").isEmpty
        updateChartRootView()
        setNeedsLayout()
    }

    private func updateChartRootView() {
        guard let spec else {
            hostingController.rootView = AnyView(EmptyView())
            return
        }

        // Tooltip should use high-contrast semantic colors instead of code-block gray.
        let tooltipBackground = UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 0.96)
            }
            return UIColor.white.withAlphaComponent(0.97)
        }
        let style = ChartTooltipStyle(
            background: Color(uiColor: tooltipBackground),
            border: Color(uiColor: .separator).opacity(0.55),
            primaryText: Color(uiColor: .label),
            secondaryText: Color(uiColor: .secondaryLabel)
        )
        hostingController.rootView = AnyView(ChartRenderView(spec: spec, tooltipStyle: style))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let spec else { return }

        let contentFrame = contentView.bounds
        cardView.frame = contentFrame

        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 10
        let titleHeight: CGFloat = titleLabel.isHidden ? 0 : 22

        if !titleLabel.isHidden {
            titleLabel.frame = CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: cardView.bounds.width - horizontalPadding * 2,
                height: titleHeight
            )
        }

        let chartTop = verticalPadding + titleHeight + (titleLabel.isHidden ? 0 : 6)
        let chartHeight = min(spec.resolvedHeight, max(0, cardView.bounds.height - chartTop - verticalPadding))
        hostingController.view.frame = CGRect(
            x: horizontalPadding,
            y: chartTop,
            width: cardView.bounds.width - horizontalPadding * 2,
            height: chartHeight
        )
    }

    static func contentHeight(for spec: ChartSpec, containerWidth _: CGFloat) -> CGFloat {
        let titleHeight: CGFloat = ((spec.title ?? "").isEmpty ? 0 : 22)
        let titleSpacing: CGFloat = titleHeight > 0 ? 6 : 0
        let verticalPadding: CGFloat = 20
        return ceil(spec.resolvedHeight + titleHeight + titleSpacing + verticalPadding)
    }

    private func configureSubviews() {
        contentView.addSubview(cardView)
        cardView.layer.cornerRadius = 12
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        cardView.clipsToBounds = true

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.numberOfLines = 1
        cardView.addSubview(titleLabel)

        hostingController.view.backgroundColor = .clear
        cardView.addSubview(hostingController.view)
    }
}

private struct ChartRenderView: View {
    let spec: ChartSpec
    let tooltipStyle: ChartTooltipStyle
    @State private var selectedX: String?
    @State private var selectedRuleY: Double?
    @State private var selectedRectangleIndex: Int?
    @State private var selectedPieAngle: Double?
    @State private var lastHapticToken: String?

    var body: some View {
        Group {
            switch spec.kind {
            case .line:
                lineChart
            case .area:
                areaChart
            case .bar:
                barChart
            case .point:
                pointChart
            case .rule:
                ruleChart
            case .rectangle:
                rectangleChart
            case .pie:
                pieChart
            }
        }
        .onChange(of: selectedX) { _, value in
            emitHaptic(token: value.map { "x:\($0)" })
        }
        .onChange(of: selectedRuleY) { _, value in
            guard let value else {
                emitHaptic(token: nil)
                return
            }
            emitHaptic(token: "rule:\(value)")
        }
        .onChange(of: selectedRectangleIndex) { _, value in
            emitHaptic(token: value.map { "rect:\($0)" })
        }
        .onChange(of: selectedPieAngle) { _, _ in
            if let selectedName = currentSelectedPieName() {
                emitHaptic(token: "pie:\(selectedName)")
            }
        }
    }

    private func currentSelectedPieName() -> String? {
        guard let pie = spec.pie else { return nil }
        return selectedPieInfo(in: pie)?.item.name
    }

    private func emitHaptic(token: String?) {
        guard let token, token != lastHapticToken else {
            if token == nil { lastHapticToken = nil }
            return
        }
        let feedback = UISelectionFeedbackGenerator()
        feedback.selectionChanged()
        lastHapticToken = token
    }

    private func tooltip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(tooltipStyle.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tooltipStyle.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tooltipStyle.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    private func tooltipSecondaryText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tooltipStyle.secondaryText)
    }

    private func tooltipPrimaryText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tooltipStyle.primaryText)
    }

    @ViewBuilder
    private var lineChart: some View {
        if let line = spec.line {
            Chart {
                ForEach(Array(line.series.enumerated()), id: \.offset) { _, series in
                    ForEach(Array(line.x.enumerated()), id: \.offset) { index, xValue in
                        LineMark(
                            x: .value("X", xValue),
                            y: .value("Y", series.y[index])
                        )
                        .foregroundStyle(by: .value("Series", series.name))

                        PointMark(
                            x: .value("X", xValue),
                            y: .value("Y", series.y[index])
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                    }
                }

                if let selectedIndex = selectedIndex(in: line.x) {
                    selectedSelectionMarks(xValues: line.x, series: line.series, selectedIndex: selectedIndex)
                }
            }
            .overlay(alignment: .topLeading) {
                if let selectedIndex = selectedIndex(in: line.x) {
                    selectionSummary(for: line.x[selectedIndex], series: line.series, selectedIndex: selectedIndex)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .chartOverlay { proxy in
                selectionOverlay(proxy: proxy)
            }
            .chartLegend(position: .bottom, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var areaChart: some View {
        if let area = spec.area {
            Chart {
                ForEach(Array(area.series.enumerated()), id: \.offset) { _, series in
                    ForEach(Array(area.x.enumerated()), id: \.offset) { index, xValue in
                        AreaMark(
                            x: .value("X", xValue),
                            y: .value("Y", series.y[index])
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                    }
                }

                if let selectedIndex = selectedIndex(in: area.x) {
                    selectedSelectionMarks(xValues: area.x, series: area.series, selectedIndex: selectedIndex)
                }
            }
            .overlay(alignment: .topLeading) {
                if let selectedIndex = selectedIndex(in: area.x) {
                    selectionSummary(for: area.x[selectedIndex], series: area.series, selectedIndex: selectedIndex)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .chartOverlay { proxy in
                selectionOverlay(proxy: proxy)
            }
            .chartLegend(position: .bottom, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var barChart: some View {
        if let bar = spec.bar {
            Chart {
                ForEach(Array(bar.series.enumerated()), id: \.offset) { _, series in
                    ForEach(Array(bar.x.enumerated()), id: \.offset) { index, xValue in
                        BarMark(
                            x: .value("X", xValue),
                            y: .value("Y", series.y[index])
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                    }
                }

                if let selectedIndex = selectedIndex(in: bar.x) {
                    selectedSelectionMarks(xValues: bar.x, series: bar.series, selectedIndex: selectedIndex)
                }
            }
            .overlay(alignment: .topLeading) {
                if let selectedIndex = selectedIndex(in: bar.x) {
                    selectionSummary(for: bar.x[selectedIndex], series: bar.series, selectedIndex: selectedIndex)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .chartOverlay { proxy in
                selectionOverlay(proxy: proxy)
            }
            .chartLegend(position: .bottom, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var pointChart: some View {
        if let point = spec.point {
            Chart {
                ForEach(Array(point.series.enumerated()), id: \.offset) { _, series in
                    ForEach(Array(point.x.enumerated()), id: \.offset) { index, xValue in
                        PointMark(
                            x: .value("X", xValue),
                            y: .value("Y", series.y[index])
                        )
                        .foregroundStyle(by: .value("Series", series.name))
                    }
                }

                if let selectedIndex = selectedIndex(in: point.x) {
                    selectedSelectionMarks(xValues: point.x, series: point.series, selectedIndex: selectedIndex)
                }
            }
            .overlay(alignment: .topLeading) {
                if let selectedIndex = selectedIndex(in: point.x) {
                    selectionSummary(for: point.x[selectedIndex], series: point.series, selectedIndex: selectedIndex)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .chartOverlay { proxy in
                selectionOverlay(proxy: proxy)
            }
            .chartLegend(position: .bottom, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var ruleChart: some View {
        if let rule = spec.rule {
            Chart {
                ForEach(Array(rule.yValues.enumerated()), id: \.offset) { index, value in
                    RuleMark(y: .value("Y", value))
                        .foregroundStyle(by: .value("Rule", "Rule \(index + 1)"))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                }

                if let selected = selectedRuleY {
                    RuleMark(y: .value("Selected Rule", selected))
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 3))
                }
            }
            .overlay(alignment: .topLeading) {
                if let selected = selectedRuleY {
                    ruleValueTooltip(selected)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .chartOverlay { proxy in
                ruleSelectionOverlay(proxy: proxy, values: rule.yValues)
            }
            .chartLegend(position: .bottom, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var rectangleChart: some View {
        if let rectangle = spec.rectangle {
            Chart {
                ForEach(Array(rectangle.items.enumerated()), id: \.offset) { index, item in
                    RectangleMark(
                        xStart: .value("X Start", item.xStart),
                        xEnd: .value("X End", item.xEnd),
                        yStart: .value("Y Start", item.yStart),
                        yEnd: .value("Y End", item.yEnd)
                    )
                    .foregroundStyle(by: .value("Range", item.label))
                    .opacity(selectedRectangleIndex == nil ? 0.55 : (selectedRectangleIndex == index ? 0.9 : 0.2))

                    if selectedRectangleIndex == index {
                        RectangleMark(
                            xStart: .value("Selected X Start", item.xStart),
                            xEnd: .value("Selected X End", item.xEnd),
                            yStart: .value("Selected Y Start", item.yStart),
                            yEnd: .value("Selected Y End", item.yEnd)
                        )
                        .foregroundStyle(.clear)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let selectedRectangleIndex,
                   selectedRectangleIndex >= 0,
                   selectedRectangleIndex < rectangle.items.count
                {
                    rectangleSummary(rectangle.items[selectedRectangleIndex])
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .chartOverlay { proxy in
                rectangleSelectionOverlay(proxy: proxy, items: rectangle.items)
            }
            .chartLegend(position: .bottom, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var pieChart: some View {
        if let pie = spec.pie {
            let selectedName = selectedPieInfo(in: pie)?.item.name

            Chart(pie.items, id: \.name) { item in
                let isSelected = selectedName == item.name
                SectorMark(
                    angle: .value("Value", item.value),
                    innerRadius: .ratio(0.55),
                    outerRadius: .ratio(isSelected ? 1 : 0.9),
                    angularInset: 1.5
                )
                .foregroundStyle(by: .value("Item", item.name))
                .opacity(selectedName == nil ? 1 : (isSelected ? 1 : 0.35))
            }
            .chartAngleSelection(value: $selectedPieAngle)
            .overlay {
                if let info = selectedPieInfo(in: pie) {
                    pieSummary(name: info.item.name, value: info.item.value, percent: info.percent)
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    private func selectedIndex(in xValues: [String]) -> Int? {
        guard let selectedX else { return nil }
        return xValues.firstIndex(of: selectedX)
    }

    @ChartContentBuilder
    private func selectedSelectionMarks(
        xValues: [String],
        series: [ChartSpec.LineSeries],
        selectedIndex: Int
    ) -> some ChartContent {
        if selectedIndex >= 0, selectedIndex < xValues.count {
            let xValue = xValues[selectedIndex]
            RuleMark(x: .value("Selection", xValue))
                .foregroundStyle(.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                PointMark(
                    x: .value("Selection X", xValue),
                    y: .value("Selection Y", item.y[selectedIndex])
                )
                .symbolSize(60)
                .foregroundStyle(by: .value("Series", item.name))
            }
        }
    }

    private func selectionOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let origin = geometry[proxy.plotAreaFrame].origin
                            let x = gesture.location.x - origin.x
                            guard x >= 0, x < proxy.plotAreaSize.width else { return }
                            if let nearestX: String = proxy.value(atX: x) {
                                selectedX = nearestX
                            }
                        }
                )
                .onTapGesture {
                    selectedX = nil
                }
        }
    }

    private func ruleSelectionOverlay(proxy: ChartProxy, values: [Double]) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let origin = geometry[proxy.plotAreaFrame].origin
                            let y = gesture.location.y - origin.y
                            guard y >= 0, y < proxy.plotAreaSize.height else { return }
                            if let value: Double = proxy.value(atY: y) {
                                selectedRuleY = nearestValue(to: value, in: values)
                            }
                        }
                )
                .onTapGesture {
                    selectedRuleY = nil
                }
        }
    }

    private func rectangleSelectionOverlay(proxy: ChartProxy, items: [ChartSpec.RectangleItem]) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let origin = geometry[proxy.plotAreaFrame].origin
                            let x = gesture.location.x - origin.x
                            let y = gesture.location.y - origin.y
                            guard x >= 0, x < proxy.plotAreaSize.width, y >= 0, y < proxy.plotAreaSize.height else { return }
                            guard let xValue: String = proxy.value(atX: x),
                                  let yValue: Double = proxy.value(atY: y)
                            else {
                                return
                            }
                            selectedRectangleIndex = rectangleIndex(containingX: xValue, y: yValue, in: items)
                        }
                )
                .onTapGesture {
                    selectedRectangleIndex = nil
                }
        }
    }

    private func rectangleIndex(containingX xValue: String, y: Double, in items: [ChartSpec.RectangleItem]) -> Int? {
        let domain = rectangleDomain(items: items)
        guard let xIndex = domain.firstIndex(of: xValue) else { return nil }

        let candidates = items.enumerated().compactMap { index, item -> (Int, Double)? in
            guard let start = domain.firstIndex(of: item.xStart),
                  let end = domain.firstIndex(of: item.xEnd)
            else {
                return nil
            }

            let minX = min(start, end)
            let maxX = max(start, end)
            let containsX = xIndex >= minX && xIndex <= maxX
            let containsY = y >= item.yStart && y <= item.yEnd
            guard containsX, containsY else { return nil }

            let center = (item.yStart + item.yEnd) / 2
            return (index, abs(y - center))
        }

        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    private func rectangleDomain(items: [ChartSpec.RectangleItem]) -> [String] {
        var domain: [String] = []
        for item in items {
            if !domain.contains(item.xStart) {
                domain.append(item.xStart)
            }
            if !domain.contains(item.xEnd) {
                domain.append(item.xEnd)
            }
        }
        return domain
    }

    private func selectionSummary(for xValue: String, series: [ChartSpec.LineSeries], selectedIndex: Int) -> some View {
        tooltip {
            VStack(alignment: .leading, spacing: 2) {
                tooltipPrimaryText(xValue)
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    tooltipSecondaryText("\(item.name): \(formatNumber(item.y[selectedIndex]))")
                }
            }
        }
    }

    private func ruleValueTooltip(_ value: Double) -> some View {
        tooltip {
            tooltipPrimaryText(formatNumber(value))
        }
    }

    private func rectangleSummary(_ item: ChartSpec.RectangleItem) -> some View {
        tooltip {
            VStack(alignment: .leading, spacing: 2) {
                tooltipPrimaryText(item.label)
                tooltipSecondaryText("X: \(item.xStart) - \(item.xEnd)")
                tooltipSecondaryText(
                    "Y: \(formatNumber(item.yStart)) - \(formatNumber(item.yEnd))"
                )
            }
        }
    }

    private func pieSummary(name: String, value: Double, percent: Double) -> some View {
        tooltip {
            VStack(spacing: 2) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tooltipStyle.primaryText)
                Text("\(formatNumber(value)) (\(formatPercent(percent)))")
                    .font(.caption2)
                    .foregroundStyle(tooltipStyle.secondaryText)
            }
        }
    }

    private func formatNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == floor(rounded) {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.2f", rounded)
    }

    private func formatPercent(_ value: Double) -> String {
        let clamped = max(0, min(1, value)) * 100
        return String(format: "%.1f%%", clamped)
    }

    private func nearestValue(to value: Double, in values: [Double]) -> Double? {
        values.min(by: { abs($0 - value) < abs($1 - value) })
    }

    private func selectedPieInfo(in pie: ChartSpec.PieData) -> (item: ChartSpec.PieItem, percent: Double)? {
        guard let selectedPieAngle else { return nil }
        let total = pie.items.reduce(0) { $0 + $1.value }
        guard total > 0 else { return nil }

        let normalized = selectedPieAngle.truncatingRemainder(dividingBy: total)
        var current: Double = 0
        for item in pie.items {
            let next = current + item.value
            if normalized >= current, normalized < next {
                return (item, item.value / total)
            }
            current = next
        }

        guard let last = pie.items.last else { return nil }
        return (last, last.value / total)
    }
}

private struct ChartTooltipStyle {
    let background: Color
    let border: Color
    let primaryText: Color
    let secondaryText: Color
}
