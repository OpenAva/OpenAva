//
//  ChartSpec.swift
//  ChatUI
//
//  Structured chart payload decoded from ```chart JSON blocks.
//

import CoreGraphics
import Foundation

struct ChartSpec: Hashable, Codable {
    enum Kind: String, Hashable, Codable {
        case line
        case area
        case bar
        case point
        case rule
        case rectangle
        case pie
    }

    struct LineSeries: Hashable, Codable {
        let name: String
        let y: [Double]
    }

    struct LineData: Hashable, Codable {
        let x: [String]
        let series: [LineSeries]
    }

    struct PieItem: Hashable, Codable {
        let name: String
        let value: Double
    }

    struct PieData: Hashable, Codable {
        let items: [PieItem]
    }

    struct RuleData: Hashable, Codable {
        let yValues: [Double]
    }

    struct RectangleItem: Hashable, Codable {
        let label: String
        let xStart: String
        let xEnd: String
        let yStart: Double
        let yEnd: Double
    }

    struct RectangleData: Hashable, Codable {
        let items: [RectangleItem]
    }

    let kind: Kind
    let title: String?
    let height: CGFloat?
    let line: LineData?
    let area: LineData?
    let bar: LineData?
    let point: LineData?
    let rule: RuleData?
    let rectangle: RectangleData?
    let pie: PieData?
}

extension ChartSpec {
    /// Keep chart row height predictable and avoid extreme payload values.
    var resolvedHeight: CGFloat {
        let fallback: CGFloat = 220
        guard let height else { return fallback }
        return min(360, max(160, height))
    }

    var isValid: Bool {
        switch kind {
        case .line:
            return isValidSeriesData(line)
        case .area:
            return isValidSeriesData(area)
        case .bar:
            return isValidSeriesData(bar)
        case .point:
            return isValidSeriesData(point)
        case .rule:
            guard let rule, !rule.yValues.isEmpty else { return false }
            return true
        case .rectangle:
            guard let rectangle, !rectangle.items.isEmpty else { return false }
            return rectangle.items.allSatisfy {
                !$0.label.isEmpty && !$0.xStart.isEmpty && !$0.xEnd.isEmpty && $0.yEnd >= $0.yStart
            }
        case .pie:
            guard let pie, !pie.items.isEmpty else { return false }
            return pie.items.allSatisfy { !$0.name.isEmpty && $0.value >= 0 }
        }
    }

    private func isValidSeriesData(_ data: LineData?) -> Bool {
        guard let data,
              !data.x.isEmpty,
              !data.series.isEmpty
        else {
            return false
        }
        return data.series.allSatisfy { !$0.name.isEmpty && $0.y.count == data.x.count }
    }
}
