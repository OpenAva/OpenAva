//
//  MapSpec.swift
//  ChatUI
//
//  Structured map payload decoded from ```map JSON blocks.
//

import CoreGraphics
import Foundation

struct MapSpec: Hashable, Codable {
    struct Coordinate: Hashable, Codable {
        let lat: Double
        let lon: Double

        var isValid: Bool {
            (-90 ... 90).contains(lat) && (-180 ... 180).contains(lon)
        }
    }

    struct Marker: Hashable, Codable {
        let lat: Double
        let lon: Double
        let title: String?
        let tint: String?

        var coordinate: Coordinate {
            .init(lat: lat, lon: lon)
        }
    }

    struct Polyline: Hashable, Codable {
        let coordinates: [Coordinate]
        let color: String?
    }

    struct Polygon: Hashable, Codable {
        let coordinates: [Coordinate]
        let fillColor: String?
        let strokeColor: String?
    }

    let title: String?
    let height: CGFloat?
    let center: Coordinate?
    let span: Double?
    let markers: [Marker]?
    let polylines: [Polyline]?
    let polygons: [Polygon]?
}

extension MapSpec {
    /// Keep map row height predictable and avoid extreme payload values.
    var resolvedHeight: CGFloat {
        let fallback: CGFloat = 240
        guard let height else { return fallback }
        return min(360, max(160, height))
    }

    var resolvedSpan: Double {
        let fallback = 0.05
        guard let span else { return fallback }
        return min(120, max(0.001, span))
    }

    var allCoordinates: [Coordinate] {
        let markerCoordinates = markers?.map(\.coordinate) ?? []
        let polylineCoordinates = polylines?.flatMap(\.coordinates) ?? []
        let polygonCoordinates = polygons?.flatMap(\.coordinates) ?? []
        let centerCoordinate = center.map { [$0] } ?? []
        return (centerCoordinate + markerCoordinates + polylineCoordinates + polygonCoordinates)
            .filter(\.isValid)
    }

    var isValid: Bool {
        let hasPolyline = polylines?.contains(where: { $0.coordinates.filter(\.isValid).count >= 2 }) ?? false
        let hasPolygon = polygons?.contains(where: { $0.coordinates.filter(\.isValid).count >= 3 }) ?? false
        let hasMarker = markers?.contains(where: { $0.coordinate.isValid }) ?? false
        return center?.isValid == true || hasMarker || hasPolyline || hasPolygon
    }
}
