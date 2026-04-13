//
//  MapMessageView.swift
//  ChatUI
//
//  Renders map segments extracted from markdown messages.
//

import MapKit
import SwiftUI
import UIKit

final class MapMessageView: MessageListRowView {
    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let hostingController = UIHostingController(rootView: AnyView(EmptyView()))

    private var spec: MapSpec?

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

        let cardBackground = UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 0.82)
            }
            return UIColor(red: 0.985, green: 0.982, blue: 0.972, alpha: 0.98)
        }
        cardView.backgroundColor = cardBackground
        updateMapRootView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spec = nil
        titleLabel.text = nil
        hostingController.rootView = AnyView(EmptyView())
    }

    func configure(with spec: MapSpec) {
        self.spec = spec
        titleLabel.text = spec.title
        titleLabel.isHidden = (spec.title ?? "").isEmpty
        updateMapRootView()
        setNeedsLayout()
    }

    private func updateMapRootView() {
        guard let spec else {
            hostingController.rootView = AnyView(EmptyView())
            return
        }

        hostingController.rootView = AnyView(MapRenderView(spec: spec))
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

        let mapTop = verticalPadding + titleHeight + (titleLabel.isHidden ? 0 : 6)
        let mapHeight = min(spec.resolvedHeight, max(0, cardView.bounds.height - mapTop - verticalPadding))
        hostingController.view.frame = CGRect(
            x: horizontalPadding,
            y: mapTop,
            width: cardView.bounds.width - horizontalPadding * 2,
            height: mapHeight
        )
    }

    static func contentHeight(for spec: MapSpec, containerWidth _: CGFloat) -> CGFloat {
        let titleHeight: CGFloat = ((spec.title ?? "").isEmpty ? 0 : 22)
        let titleSpacing: CGFloat = titleHeight > 0 ? 6 : 0
        let verticalPadding: CGFloat = 20
        return ceil(spec.resolvedHeight + titleHeight + titleSpacing + verticalPadding)
    }

    private func configureSubviews() {
        contentView.addSubview(cardView)
        cardView.layer.cornerRadius = ChatUIDesign.Radius.card
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true

        titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        titleLabel.textColor = ChatUIDesign.Color.offBlack
        titleLabel.numberOfLines = 1
        cardView.addSubview(titleLabel)

        hostingController.view.backgroundColor = .clear
        cardView.addSubview(hostingController.view)
    }
}

private struct MapRenderView: View {
    let spec: MapSpec

    var body: some View {
        Map(initialPosition: .region(initialRegion)) {
            ForEach(Array((spec.markers ?? []).enumerated()), id: \.offset) { _, marker in
                let coordinate = marker.coordinate.clLocationCoordinate2D
                Marker(marker.title ?? "Location", coordinate: coordinate)
                    .tint(ColorParser.color(from: marker.tint, fallback: .red))
            }

            ForEach(Array((spec.polylines ?? []).enumerated()), id: \.offset) { _, polyline in
                let coordinates = polyline.coordinates
                    .filter(\.isValid)
                    .map(\.clLocationCoordinate2D)
                if coordinates.count >= 2 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(ColorParser.color(from: polyline.color, fallback: .blue), lineWidth: 3)
                }
            }

            ForEach(Array((spec.polygons ?? []).enumerated()), id: \.offset) { _, polygon in
                let coordinates = polygon.coordinates
                    .filter(\.isValid)
                    .map(\.clLocationCoordinate2D)
                if coordinates.count >= 3 {
                    MapPolygon(coordinates: coordinates)
                        .foregroundStyle(ColorParser.color(from: polygon.fillColor, fallback: .green).opacity(0.22))

                    MapPolyline(coordinates: closedCoordinates(for: coordinates))
                        .stroke(ColorParser.color(from: polygon.strokeColor, fallback: .green), lineWidth: 2)
                }
            }
        }
        .mapStyle(.standard)
    }

    private var initialRegion: MKCoordinateRegion {
        if let center = spec.center, center.isValid {
            let coordinate = center.clLocationCoordinate2D
            let delta = spec.resolvedSpan
            return MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
            )
        }

        let coordinates = spec.allCoordinates.map(\.clLocationCoordinate2D)
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: spec.resolvedSpan, longitudeDelta: spec.resolvedSpan)
            )
        }

        guard coordinates.count > 1 else {
            return MKCoordinateRegion(
                center: first,
                span: MKCoordinateSpan(latitudeDelta: spec.resolvedSpan, longitudeDelta: spec.resolvedSpan)
            )
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(),
              let maxLat = latitudes.max(),
              let minLon = longitudes.min(),
              let maxLon = longitudes.max()
        else {
            return MKCoordinateRegion(
                center: first,
                span: MKCoordinateSpan(latitudeDelta: spec.resolvedSpan, longitudeDelta: spec.resolvedSpan)
            )
        }

        let latPadding = max((maxLat - minLat) * 0.35, spec.resolvedSpan * 0.25)
        let lonPadding = max((maxLon - minLon) * 0.35, spec.resolvedSpan * 0.25)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.001, maxLat - minLat + latPadding),
                longitudeDelta: max(0.001, maxLon - minLon + lonPadding)
            )
        )
    }

    private func closedCoordinates(for coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return coordinates }
        return coordinates + [first]
    }
}

private extension MapSpec.Coordinate {
    var clLocationCoordinate2D: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

private enum ColorParser {
    static func color(from value: String?, fallback: Color) -> Color {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return fallback
        }

        if let named = namedColors[value.lowercased()] {
            return named
        }

        if let hexColor = hexColor(from: value) {
            return hexColor
        }

        return fallback
    }

    private static let namedColors: [String: Color] = [
        "red": .red,
        "orange": .orange,
        "yellow": .yellow,
        "green": .green,
        "mint": .mint,
        "teal": .teal,
        "cyan": .cyan,
        "blue": .blue,
        "indigo": .indigo,
        "purple": .purple,
        "pink": .pink,
        "brown": .brown,
        "gray": .gray,
        "grey": .gray,
        "black": .black,
        "white": .white,
    ]

    private static func hexColor(from rawValue: String) -> Color? {
        let hex = rawValue.hasPrefix("#") ? String(rawValue.dropFirst()) : rawValue
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16)
        else {
            return nil
        }

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        if hex.count == 8 {
            red = Double((value & 0xFF00_0000) >> 24) / 255
            green = Double((value & 0x00FF_0000) >> 16) / 255
            blue = Double((value & 0x0000_FF00) >> 8) / 255
            alpha = Double(value & 0x0000_00FF) / 255
        } else {
            red = Double((value & 0xFF0000) >> 16) / 255
            green = Double((value & 0x00FF00) >> 8) / 255
            blue = Double(value & 0x0000FF) / 255
            alpha = 1
        }

        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
