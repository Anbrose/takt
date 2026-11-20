import Foundation
import TaktAPI

/// Hands routes over to Google Maps with a plain Maps URL (no API key, no billing):
/// https://developers.google.com/maps/documentation/urls/get-started
/// On iOS the link opens the Google Maps app when it is installed, otherwise the website.
///
/// Device tests (2026-11-14) decided the shape:
/// - Places go by name + address, never bare coordinates — Google snaps coordinates to whatever
///   business happens to be nearest ("Central Park" instead of Universal Studios Japan).
/// - Public transport can't route through waypoints ("could not calculate public transport
///   directions"), so the whole route opens in driving mode; transit works one leg at a time.
public enum MapsLink {
    public enum Mode: String, Sendable { case driving, walking, transit }

    /// Google Maps accepts up to 9 waypoints in a URL; extra stops are dropped.
    public static let maxWaypoints = 9

    /// What Google should search for to find the task's place; nil for 未定位 tasks.
    public static func query(_ t: TaskSummary) -> String? {
        guard let lat = t.lat, let lng = t.lng else { return nil }
        let address = t.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = t.place.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty { return place.isEmpty ? address : "\(place) \(address)" }
        // Older tasks without an address: coordinates still land in the right spot.
        return "\(lat),\(lng)"
    }

    /// The located tasks in order, first = origin, last = destination, the rest as waypoints.
    /// nil when fewer than two tasks have a location.
    public static func route(_ tasks: [TaskSummary], mode: Mode = .driving) -> URL? {
        let stops = tasks.compactMap(query)
        guard stops.count >= 2, let first = stops.first, let last = stops.last else { return nil }
        var items = [("origin", encode(first)), ("destination", encode(last))]
        let middle = stops.dropFirst().dropLast().prefix(maxWaypoints)
        if !middle.isEmpty { items.append(("waypoints", middle.map(encode).joined(separator: "%7C"))) }
        items.append(("travelmode", mode.rawValue))
        let query = items.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        return URL(string: "https://www.google.com/maps/dir/?api=1&\(query)")
    }

    private static let unreserved = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
