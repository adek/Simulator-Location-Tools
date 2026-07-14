import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

struct ImportedGPX: Sendable {
    let name: String?
    let points: [RoutePoint]
}

enum GPXError: LocalizedError, Equatable {
    case unreadable
    case malformed(String)
    case insufficientPoints

    var errorDescription: String? {
        switch self {
        case .unreadable: "The GPX file could not be read."
        case .malformed(let message): "The GPX file is malformed: \(message)"
        case .insufficientPoints: "The GPX file must contain at least two valid waypoints, route points, or track points."
        }
    }
}

enum GPXParser {
    static func parse(data: Data) throws -> ImportedGPX {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw GPXError.malformed(parser.parserError?.localizedDescription ?? "Unknown XML error")
        }
        let points: [RoutePoint]
        if delegate.trackPoints.count >= 2 { points = delegate.trackPoints }
        else if delegate.routePoints.count >= 2 { points = delegate.routePoints }
        else { points = delegate.waypoints }
        guard points.count >= 2 else { throw GPXError.insufficientPoints }
        return ImportedGPX(name: delegate.routeName, points: points)
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    var waypoints: [RoutePoint] = []
    var routePoints: [RoutePoint] = []
    var trackPoints: [RoutePoint] = []
    var routeName: String?

    private var currentPointElement: String?
    private var latitude: Double?
    private var longitude: Double?
    private var elevation: Double?
    private var timestamp: Date?
    private var text = ""
    private var routeDepth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = elementName.lowercased()
        text = ""
        if element == "trk" || element == "rte" { routeDepth += 1 }
        guard ["wpt", "rtept", "trkpt"].contains(element) else { return }
        currentPointElement = element
        latitude = attributeDict["lat"].flatMap(Double.init)
        longitude = attributeDict["lon"].flatMap(Double.init)
        elevation = nil
        timestamp = nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentPointElement != nil {
            if element == "ele" { elevation = Double(value) }
            if element == "time" { timestamp = ISO8601DateFormatter().date(from: value) }
        } else if element == "name", routeDepth > 0, routeName == nil, !value.isEmpty {
            routeName = value
        }

        if element == currentPointElement {
            if let latitude, let longitude,
               (-90...90).contains(latitude), (-180...180).contains(longitude) {
                let point = RoutePoint(latitude: latitude, longitude: longitude, elevation: elevation, timestamp: timestamp)
                switch currentPointElement {
                case "trkpt": trackPoints.append(point)
                case "rtept": routePoints.append(point)
                default: waypoints.append(point)
                }
            }
            currentPointElement = nil
            latitude = nil
            longitude = nil
        }
        if element == "trk" || element == "rte" { routeDepth = max(0, routeDepth - 1) }
        text = ""
    }
}

struct GPXFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.gpx, .xml] }
    let routeName: String
    let points: [RoutePoint]

    init(routeName: String, points: [RoutePoint]) {
        self.routeName = routeName
        self.points = points
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw GPXError.unreadable }
        let imported = try GPXParser.parse(data: data)
        routeName = imported.name ?? "Imported Route"
        points = imported.points
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: encodedData())
    }

    func encodedData() -> Data { Data(xml.utf8) }

    private var xml: String {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<gpx version=\"1.1\" creator=\"Simulator Location Tools\" xmlns=\"http://www.topografix.com/GPX/1/1\">",
            "  <metadata><name>\(routeName.xmlEscaped)</name></metadata>"
        ]
        let formatter = ISO8601DateFormatter()
        for (index, point) in points.enumerated() {
            lines.append("  <wpt lat=\"\(CoordinateParser.commandString(point.latitude))\" lon=\"\(CoordinateParser.commandString(point.longitude))\">")
            if let elevation = point.elevation {
                lines.append("    <ele>\(CoordinateParser.commandString(elevation))</ele>")
            }
            if let timestamp = point.timestamp {
                lines.append("    <time>\(formatter.string(from: timestamp))</time>")
            }
            lines.append("    <name>Point \(index + 1)</name>")
            lines.append("  </wpt>")
        }
        lines.append("</gpx>")
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
