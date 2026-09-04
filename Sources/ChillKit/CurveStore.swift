import Foundation

public enum CurveStoreError: Error, CustomStringConvertible {
    case notFound(name: String, directory: URL)
    case unreadable(URL, Error)

    public var description: String {
        switch self {
        case .notFound(let name, let directory):
            return "no curve \"\(name)\" in \(directory.path)"
        case .unreadable(let url, let error):
            return "\(url.path) does not parse: \(error)"
        }
    }
}

/// The curves on disk: `<state>/curves/<name>.json`, one file per curve,
/// the file's stem IS the curve's name. Owned by the app and the CLI
/// (never the daemon, which is handed a curve over the wire). In the demo
/// world the directory is the `-demo` sibling, seeded on first use.
public struct CurveStore: Sendable {
    public let directory: URL

    public init(demo: Demo) throws {
        directory = demo.curves
        guard demo.on, !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for curve in Demo.seedCurves { try save(curve) }
    }

    public func url(_ name: String) -> URL {
        directory.appending(path: "\(name).json")
    }

    /// Every curve, by name. A file that does not parse is an error, not a
    /// skipped entry: a curve the app wrote is one the app can read.
    public func list() throws -> [Curve] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        return try files.map(read).sorted { $0.name < $1.name }
    }

    public func load(_ name: String) throws -> Curve {
        let file = url(name)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CurveStoreError.notFound(name: name, directory: directory)
        }
        return try read(file)
    }

    public func save(_ curve: Curve) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Wire.encode(curve).write(to: url(curve.name), options: .atomic)
    }

    private func read(_ file: URL) throws -> Curve {
        do {
            return try Wire.decode(Curve.self, from: Data(contentsOf: file))
        } catch {
            throw CurveStoreError.unreadable(file, error)
        }
    }
}
