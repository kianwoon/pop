import CoreLocation
import Foundation
import MapKit

/// Where a lookup's location came from.
///
/// `core`   — macOS Core Location (the real, current place).
/// `config` — the user's configured default city (a fallback when Core Location
///            is unavailable/denied).
/// `serp`   — no declared source was available; the caller must fall back to the
///            page's own inference and label it a guess. `ResolvedLocation` is
///            never produced with this source; it is the ABSENCE of a result.
enum LocationSource: String, Sendable {
    case core
    case config
    case serp
}

/// A location to embed in a lookup. Carries a CITY NAME only — no coordinates
/// are stored here, so nothing downstream can log or display a fix.
struct ResolvedLocation: Sendable, Equatable {
    var source: LocationSource
    /// The human city name ("Singapore"). The ONLY location string ever logged.
    var city: String
    /// A "city,region,country" canonical string for Google's `uule` parameter,
    /// assembled from whatever the geocoder/config supplied. No built-in place
    /// knowledge: it is composed from the source's own components.
    var canonical: String
}

/// Resolves the user's location for web lookups: Core Location first (cached
/// with a TTL), then the configured default city, else nothing (the caller
/// falls back to the page's own inference).
///
/// It never blocks a lookup for long: a denied/undetermined authorization or a
/// slow fix returns `nil` promptly, and the lookup proceeds without a location
/// rather than waiting on a permission prompt that may never be answered.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    /// How long a resolved location is reused before asking again.
    static let ttl: TimeInterval = 3600
    /// A fix that does not arrive in this many seconds is abandoned.
    static let fixTimeout: TimeInterval = 4

    private let manager = CLLocationManager()
    private var cached: (location: ResolvedLocation, at: Date)?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    /// Probe seam: `POP_LOC_FORCE=serp` forces "no location" (degradation to the
    /// page's own inference); `POP_LOC_FORCE=config:<city>` forces the config
    /// path with a given city. Unset in production.
    private static var forced: String? {
        ProcessInfo.processInfo.environment["POP_LOC_FORCE"]
    }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// The city to embed, or `nil` when no declared source is available. The
    /// caller then uses the page's own inference, labelled as a guess.
    func resolve() async -> ResolvedLocation? {
        if let forced = Self.forced {
            if forced == "serp" { return nil }
            if forced.hasPrefix("config:") {
                let city = String(forced.dropFirst("config:".count))
                return city.isEmpty ? nil : ResolvedLocation(source: .config, city: city, canonical: city)
            }
        }
        if let cached, Date().timeIntervalSince(cached.at) < Self.ttl {
            return cached.location
        }
        if let core = await coreLocation() {
            cached = (core, Date())
            return core
        }
        if let configured = Self.configuredDefaultCity() {
            return ResolvedLocation(source: .config, city: configured, canonical: configured)
        }
        return nil
    }

    /// The Core Location authorization state, for a probe to report honestly.
    var authorizationLabel: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: return "authorized_always"
        case .authorizedWhenInUse: return "authorized_when_in_use"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    /// Core Location, or nil when denied/restricted/undetermined/too slow.
    private func coreLocation() async -> ResolvedLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            // Ask, but do NOT wait: an unanswered prompt must not stall the
            // lookup. The next lookup sees the new authorization status.
            // A probe can set `POP_LOC_NO_PROMPT=1` to observe `.notDetermined`
            // without raising a system dialog.
            if ProcessInfo.processInfo.environment["POP_LOC_NO_PROMPT"] != "1" {
                manager.requestWhenInUseAuthorization()
            }
            return nil
        case .authorizedWhenInUse, .authorizedAlways:
            guard let fix = await requestFix() else { return nil }
            return await reverseGeocode(fix)
        @unknown default:
            return nil
        }
    }

    private func requestFix() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.fixTimeout))
                guard let self, let pending = self.locationContinuation else { return }
                self.locationContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    /// A city name from the fix, via MapKit's reverse geocoder. No place list
    /// here: the geocoder supplies the components, we only pick the city.
    private func reverseGeocode(_ fix: CLLocation) async -> ResolvedLocation? {
        guard let request = MKReverseGeocodingRequest(location: fix) else { return nil }
        guard let item = (try? await request.mapItems)?.first else { return nil }
        let representations = item.addressRepresentations
        let city = representations?.cityName ?? item.name
        guard let city, !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let canonical = representations?.cityWithContext(.full) ?? city
        return ResolvedLocation(source: .core, city: city, canonical: canonical)
    }

    /// The configured default city, read directly from the config file (never
    /// creating or writing anything). `nil` when unset.
    static func configuredDefaultCity() -> String? {
        guard let data = try? Data(contentsOf: PopConfig.configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let city = (object["defaultCity"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !city.isEmpty
        else { return nil }
        return city
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            guard let self, let pending = self.locationContinuation else { return }
            self.locationContinuation = nil
            pending.resume(returning: locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, let pending = self.locationContinuation else { return }
            self.locationContinuation = nil
            pending.resume(returning: nil)
        }
    }
}
