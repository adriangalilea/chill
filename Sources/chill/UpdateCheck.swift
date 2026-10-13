import AppKit
import ChillKit
import Foundation

// THE UPDATE CHECK: the app's one request to the network, and the daemon makes
// none. Once a day, while it is on (the app menu's "check for updates daily", on
// until turned off), the app asks chill.untitled.garden/appcast.xml for the
// newest version, carrying only this install's random code (`install=`, made
// once, tied to nothing about the person or the Mac). The site counts the day's
// active installs under a salted hash of that code and keeps nothing else: no
// IP, no name. When the feed names a newer version than this one, the app menu
// says so and copies the command that upgrades it. A failed check tries again
// in an hour and changes nothing. The demo world never checks.

extension Model {
    private static let feed = URL(string: "https://chill.untitled.garden/appcast.xml")!
    private static let day: TimeInterval = 24 * 3600
    private static let retry: TimeInterval = 3600

    /// The version the feed names when it is newer than this one, else nil.
    var newerVersion: String? {
        guard let latest = config.latestVersion, Wire.version != "dev",
            Self.newer(latest, than: Wire.version)
        else { return nil }
        return latest
    }

    func toggleUpdateCheck() {
        config.updateCheck.toggle()
        config.nextUpdateCheck = nil
        saveConfig()
        checkForUpdateIfDue()
    }

    /// Asks the feed when a check is due: on, not the demo, and its day has come.
    func checkForUpdateIfDue() {
        guard config.updateCheck, !demo.on, Wire.version != "dev",
            config.nextUpdateCheck.map({ $0 <= Date() }) ?? true
        else { return }
        if config.installID == nil {
            config.installID = UUID().uuidString.lowercased()
        }
        // Booked before the request leaves, so no second check overlaps it.
        config.nextUpdateCheck = Date().addingTimeInterval(Self.retry)
        saveConfig()
        var url = URLComponents(url: Self.feed, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "install", value: config.installID)]
        var request = URLRequest(url: url.url!, timeoutInterval: 10)
        request.setValue("chill/\(Wire.version)", forHTTPHeaderField: "User-Agent")
        Task {
            let latest: String? = await {
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                    (response as? HTTPURLResponse)?.statusCode == 200,
                    let text = String(data: data, encoding: .utf8)
                else { return nil }
                return Self.latestVersion(in: text)
            }()
            guard let latest else {
                log.info("update check failed, again in an hour")
                return
            }
            config.latestVersion = latest
            config.nextUpdateCheck = Date().addingTimeInterval(Self.day)
            saveConfig()
            log.info(
                "update check: latest \(latest, privacy: .public), running \(Wire.version, privacy: .public)"
            )
        }
    }

    /// brew installed this chill: its cask has a room. Then brew is how it
    /// upgrades, and nothing replaces the bundle behind brew's back.
    static var fromBrew: Bool {
        ["/opt/homebrew/Caskroom/chill", "/usr/local/Caskroom/chill"].contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// The app menu's line for a newer version: what the press does, said.
    var upgradeLine: String? {
        newerVersion.map {
            Self.fromBrew
                ? "chill \($0) is out · copy brew upgrade" : "chill \($0) is out · download"
        }
    }

    /// The way to the newer version: the brew command copied, or the download
    /// page opened for a chill that came from the dmg.
    func upgrade() {
        if Self.fromBrew {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew upgrade --cask chill", forType: .string)
        } else {
            NSWorkspace.shared.open(URL(string: "https://chill.untitled.garden")!)
        }
    }

    /// The newest version a Sparkle feed names: its first `shortVersionString`,
    /// in element or attribute form.
    static func latestVersion(in feed: String) -> String? {
        guard
            let match = feed.range(
                of: #"shortVersionString(?:>|=")(\d+\.\d+\.\d+)"#, options: .regularExpression)
        else { return nil }
        return feed[match].range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map {
            String(feed[$0])
        }
    }

    /// Whether `a` is a later version than `b`, part by part as numbers.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
