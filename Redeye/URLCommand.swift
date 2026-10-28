import Foundation

/// A command sent through the `redeye://` URL scheme, e.g. from a terminal:
///
///     open -g "redeye://activate?hours=2"
///     open -g "redeye://activate?lid=1"
///     open -g redeye://deactivate
///     open -g redeye://toggle
///
/// `activate` takes optional `seconds`, `minutes` and `hours`, which add up. Without them it keeps
/// the Mac awake indefinitely. `lid=1` keeps it awake with the lid closed too. `redeye:///activate`
/// (KeepingYouAwake's style) works too.
enum URLCommand: Equatable {
    case activate(TimeInterval?, lidClosed: Bool = false)
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
            var lidClosed = false
            let units: [String: TimeInterval] = ["seconds": 1, "minutes": 60, "hours": 60 * 60]
            for item in components.queryItems ?? [] {
                if item.name.lowercased() == "lid" {
                    switch item.value?.lowercased() {
                    case "1", "true", "yes": lidClosed = true
                    case "0", "false", "no": lidClosed = false
                    default: return nil
                    }
                    continue
                }
                guard let unit = units[item.name.lowercased()] else { continue }
                guard let value = item.value.flatMap(Double.init), value.isFinite, value > 0 else { return nil }
                duration += value * unit
                hasDuration = true
            }
            self = .activate(hasDuration ? duration : nil, lidClosed: lidClosed)
        case "deactivate":
            self = .deactivate
        case "toggle":
            self = .toggle
        default:
            return nil
        }
    }
}
