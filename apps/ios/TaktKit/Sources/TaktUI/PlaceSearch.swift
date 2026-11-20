import Foundation
import MapKit
import Observation

/// A place picked from the search: what Google Maps needs to find it again (name + address) and
/// where to draw it (coordinates).
public struct PlaceChoice: Equatable, Sendable {
    public var name: String
    public var address: String
    public var lat: Double
    public var lng: Double

    public init(name: String, address: String, lat: Double, lng: Double) {
        self.name = name
        self.address = address
        self.lat = lat
        self.lng = lng
    }
}

/// 地点联想 for 新建: Apple's `MKLocalSearchCompleter` (free, no key, works in mainland China too).
/// Type → `suggestions`; pick one → `resolve` looks up its coordinates and address.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Hashable {
        let id: Int
        let title: String
        let subtitle: String
    }

    /// At most this many rows under the field.
    nonisolated static let limit = 4

    private(set) var suggestions: [Suggestion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var completions: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.resultTypes = [.pointOfInterest, .address]
        completer.delegate = self
    }

    /// Prefer results near the level being planned (its located tasks), if any.
    func bias(to points: [CLLocationCoordinate2D]) {
        guard !points.isEmpty else { return }
        let lats = points.map(\.latitude), lngs = points.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.2, (lats.max()! - lats.min()!) * 2),
            longitudeDelta: max(0.2, (lngs.max()! - lngs.min()!) * 2))
        completer.region = MKCoordinateRegion(center: center, span: span)
    }

    func update(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            completer.cancel()
            completions = []
            suggestions = []
        } else {
            completer.queryFragment = q
        }
    }

    func clear() { update("") }

    /// Coordinates + address for a suggestion; nil when MapKit can't find it.
    func resolve(_ s: Suggestion) async -> PlaceChoice? {
        // Match by text: the list may have refreshed since the row was drawn.
        guard let completion = completions.first(where: { $0.title == s.title && $0.subtitle == s.subtitle })
        else { return nil }
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate: CLLocationCoordinate2D
        if #available(iOS 26, macOS 26, *) {
            coordinate = item.location.coordinate
        } else {
            coordinate = item.placemark.coordinate
        }
        return PlaceChoice(
            name: item.name ?? s.title,
            // The completer's subtitle is the address line Apple shows for the place.
            address: s.subtitle,
            lat: coordinate.latitude,
            lng: coordinate.longitude
        )
    }

    // MARK: MKLocalSearchCompleterDelegate (called on the main thread)

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // MapKit calls this on the main thread, where the completer lives.
        nonisolated(unsafe) let results = Array(completer.results.prefix(Self.limit))
        MainActor.assumeIsolated {
            completions = results
            suggestions = completions.enumerated().map { i, c in
                Suggestion(id: i, title: c.title, subtitle: c.subtitle)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            completions = []
            suggestions = []
        }
    }
}
