import Foundation

/// A command sent through the `redeye://` URL scheme, e.g. from a terminal:
///
///     open -g "redeye://activate?hours=2"
///     open -g "redeye://activate?lid=1"
///     open -g "redeye://activate?lid=1&forever=1"
///     open -g redeye://deactivate
///     open -g redeye://toggle
///
/// `activate` takes optional `seconds`, `minutes` and `hours`, which add up, or `forever=1`. Without
/// any of them it uses the mode's default duration from Settings. `lid=1` keeps it awake with the
/// lid closed too. `redeye:///activate` (KeepingYouAwake's style) works too.
enum URLCommand: Equatable {
    enum Duration: Equatable {
        /// No duration given: the mode's default from Settings > Stay Awake.
        case modeDefault
        case forever
        case timed(TimeInterval)
    }

    case activate(Duration = .modeDefault, lidClosed: Bool = false)
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
            var forever = false
            var lidClosed = false
            let units: [String: TimeInterval] = ["seconds": 1, "minutes": 60, "hours": 60 * 60]
            for item in components.queryItems ?? [] {
                switch item.name.lowercased() {
                case "lid":
                    guard let value = Self.flag(item.value) else { return nil }
                    lidClosed = value
                case "forever":
                    guard let value = Self.flag(item.value) else { return nil }
                    forever = value
                default:
                    guard let unit = units[item.name.lowercased()] else { continue }
                    guard let value = item.value.flatMap(Double.init), value.isFinite, value > 0 else { return nil }
                    duration += value * unit
                    hasDuration = true
                }
            }
            // Forever plus a time contradicts itself, so reject it rather than guess.
            if forever && hasDuration { return nil }
            let chosen: Duration = forever ? .forever : hasDuration ? .timed(duration) : .modeDefault
            self = .activate(chosen, lidClosed: lidClosed)
        case "deactivate":
            self = .deactivate
        case "toggle":
            self = .toggle
        default:
            return nil
        }
    }

    /// `1`/`true`/`yes` or `0`/`false`/`no`; nil for anything else, including a missing value.
    private static func flag(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "1", "true", "yes": true
        case "0", "false", "no": false
        default: nil
        }
    }
}
