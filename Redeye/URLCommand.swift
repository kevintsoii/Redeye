import Foundation

/// A command sent through the `redeye://` URL scheme, e.g. from a terminal:
///
///     open -g "redeye://activate?hours=2"
///     open -g redeye://deactivate
///     open -g redeye://toggle
///
/// `activate` takes optional `seconds`, `minutes` and `hours`, which add up. Without them it keeps
/// the Mac awake indefinitely. `redeye:///activate` (KeepingYouAwake's style) works too.
enum URLCommand: Equatable {
    case activate(TimeInterval?)
    case deactivate
    case toggle

    static let scheme = "redeye"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let host = components.host ?? ""
        let name = (host.isEmpty ? components.path : host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        switch name {
        case "activate":
            var duration: TimeInterval = 0
            var hasDuration = false
            let units: [String: TimeInterval] = ["seconds": 1, "minutes": 60, "hours": 60 * 60]
            for item in components.queryItems ?? [] {
                guard let unit = units[item.name.lowercased()] else { continue }
                guard let value = item.value.flatMap(Double.init), value.isFinite, value > 0 else { return nil }
                duration += value * unit
                hasDuration = true
            }
            self = .activate(hasDuration ? duration : nil)
        case "deactivate":
            self = .deactivate
        case "toggle":
            self = .toggle
        default:
            return nil
        }
    }
}
