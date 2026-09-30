import ChillKit
import Foundation

/// The CLI verbs: each one a `Client` conversation rendered as the one
/// honest status line. `use` and `boost` need presence and hold it
/// themselves with `--watch`; the rest do not.
enum Verbs {
    static func die(_ message: String, exit code: Int32 = 1) -> Never {
        fputs(said(message) + "\n", stderr)
        exit(code)
    }

    /// An error as the CLI says it.
    static func said(_ message: String) -> String { "chill: \(message)" }

    /// Why `use` or `boost` without `--watch` refuses.
    static let noWatcher = "nobody at the Mac: run with --watch or open chill.app"

    static func note(_ message: String) {
        fputs("\(message)\n", stderr)
    }

    /// A client for this world, declared as `role`, or the reason none can
    /// exist here.
    static func connect(_ demo: Demo, role: Role) -> Client {
        do {
            return try Client(demo: demo, role: role)
        } catch {
            die("\(error); a bare build cannot reach chilld, run the installed chill")
        }
    }

    // MARK: - status

    static func status(json: Bool, demo: Demo) {
        let client = connect(demo, role: .cli)
        do {
            let state = try client.state()
            if json {
                print(String(decoding: Wire.encode(state, pretty: true), as: UTF8.self))
            } else {
                print(demo.mark(Status.line(state)))
                // A `daemon:` line from the daemon itself (a fanless Mac)
                // exits 1 like the others: the fans' state is unknown.
                if Status.unknown(state) != nil { exit(1) }
            }
        } catch let error as ClientError {
            // The daemon states ARE the status: on stdout, exit 1 because
            // the fans' state is unknown.
            print(demo.mark(error.description))
            exit(1)
        } catch {
            die("\(error)")
        }
    }

    // MARK: - curves

    static func curve(_ args: [String], demo: Demo) {
        let store: CurveStore
        do {
            store = try CurveStore(demo: demo)
        } catch {
            die("\(error)")
        }
        switch args.first {
        case "list":
            do {
                let curves = try store.list()
                print(demo.mark("curves in \(store.directory.path)"))
                for curve in curves { print("  \(curve.name): \(Status.points(curve))") }
                if curves.isEmpty { print("  none: draw one in chill.app") }
            } catch {
                die("\(error)")
            }
        case "show":
            guard args.count == 2 else { die("usage: chill curve show <name>") }
            do {
                let curve = try store.load(args[1])
                print(demo.mark(curve.name))
                for point in curve.points {
                    print("  \(Status.degrees(point.c))  \(Int(point.rpm)) rpm")
                }
            } catch {
                die("\(error)")
            }
        case "use":
            let flags = Flags(args.dropFirst(2))
            guard args.count >= 2, flags.rest.isEmpty else {
                die("usage: chill curve use <name> [--watch] [--take]")
            }
            let curve: Curve
            do {
                curve = try store.load(args[1])
            } catch {
                die("\(error)")
            }
            engage(demo, flags) { try $0.use(curve) }
        default:
            die("usage: chill curve list|show <name>|use <name> [--watch] [--take]")
        }
    }

    // MARK: - boost, system

    static func boost(_ args: [String], demo: Demo) {
        let flags = Flags(args[...])
        var minutes = Wire.boostMinutes
        if let word = flags.rest.first {
            guard flags.rest.count == 1, let n = Int(word), n > 0 else {
                die("usage: chill boost [minutes] [--watch] [--take]")
            }
            minutes = n
        }
        engage(demo, flags) { try $0.boost(minutes: minutes) }
    }

    static func system(demo: Demo) {
        let client = connect(demo, role: .cli)
        do {
            print(demo.mark(Status.line(try client.system())))
        } catch {
            die("\(error)")
        }
    }

    // MARK: - presence

    struct Flags {
        let watch: Bool
        let take: Bool
        let rest: [String]

        init(_ args: ArraySlice<String>) {
            watch = args.contains("--watch")
            take = args.contains("--take")
            rest = args.filter { $0 != "--watch" && $0 != "--take" }
        }
    }

    /// The presence rule for `use` and `boost`: the intent is set either
    /// way, a fan is forced only while someone watches. Without `--watch`
    /// another LIVE watcher (chill.app) must exist, exit 2 otherwise; its
    /// presence carries the intent after this process exits. With
    /// `--watch` this process becomes the watcher FIRST, which the daemon
    /// refuses `heldBy` while another is live unless `--take`; then
    /// presence at 1 Hz until Ctrl-C hands the fans back.
    private static func engage(_ demo: Demo, _ flags: Flags, _ act: (Client) throws -> State) {
        let client = connect(demo, role: flags.watch ? .watch : .cli)
        do {
            if flags.take {
                guard flags.watch else {
                    die("--take needs --watch: only a terminal that holds the fans takes them over")
                }
                _ = try client.take()
            } else if flags.watch {
                _ = try client.presence()
            } else {
                let before = try client.state()
                guard let other = before.presence, other.secondsLeft > 0 else {
                    die(noWatcher, exit: 2)
                }
            }
            print(demo.mark(Status.line(try act(client))))
        } catch {
            die("\(error)")
        }
        if flags.watch { Watch.run(client, demo: demo) }
    }

    // MARK: - log

    static func log(follow: Bool, demo: Demo) {
        if demo.on {
            print(demo.mark("log"))
            print("  the demo daemon runs in-process; nothing is written to \(Wire.logFile)")
            return
        }
        let fd = open(Wire.logFile, O_RDONLY)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: die("no \(Wire.logFile): chilld has never run here (chill daemon install)")
            default: die("\(Wire.logFile): \(String(cString: strerror(errno)))")
            }
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        func copy() {
            do {
                try FileHandle.standardOutput.write(contentsOf: try handle.readToEnd() ?? Data())
            } catch {
                die("\(Wire.logFile): \(error)")
            }
        }
        copy()
        guard follow else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename],
            queue: DispatchQueue(label: "garden.untitled.chill.log"))
        source.setEventHandler {
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                die("\(Wire.logFile) was replaced; run chill log -f again")
            }
            copy()
        }
        source.resume()
        dispatchMain()
    }
}

/// `--watch`: presence at 1 Hz, the status line reprinted when it
/// changes, SIGINT or SIGTERM = `system()` then exit. The connection
/// dying with this process is the other exit: the daemon drops the
/// presence on invalidation and Apple is back within a second.
enum Watch {
    static func run(_ client: Client, demo: Demo) -> Never {
        let queue = DispatchQueue(label: "garden.untitled.chill.watch")
        var last = ""
        var sources: [DispatchSourceProtocol] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                do {
                    print(demo.mark(Status.line(try client.system())))
                } catch {
                    Verbs.die("\(error)")
                }
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let period: DispatchTimeInterval = .milliseconds(Int(Wire.pulsePeriod.seconds * 1000))
        timer.schedule(deadline: .now() + period, repeating: period)
        timer.setEventHandler {
            do {
                let line = demo.mark(Status.line(try client.presence()))
                if line != last {
                    print(line)
                    last = line
                }
            } catch {
                Verbs.die("\(error)")
            }
        }
        timer.resume()
        sources.append(timer)
        Verbs.note(greeting)
        dispatchMain()
    }

    static let greeting = "holding the fans · Ctrl-C hands them back"
}

/// The one honest status line, from `State` alone.
enum Status {
    /// The `daemon:` line a daemon ships when the fans' state is unknown
    /// to it: this Mac has none. Keyed on the daemon's own reason, never
    /// on an empty sample (a pass whose reads failed has its own reason).
    static func unknown(_ s: State) -> String? {
        s.lastReason == Reason.noFans.description ? "daemon: \(Reason.noFans)" : nil
    }

    /// The head is the HOLDER when it is someone else, whatever the intent
    /// says: a persisted curve with no watcher still reads `foreign` while
    /// another writer forces the fans.
    static func line(_ s: State) -> String {
        if let unknown = unknown(s) { return unknown }
        let head: String
        switch s.intent {
        case _ where s.holder == .foreign: head = "foreign"
        case .system: head = "system"
        case .curve(let curve): head = curve.name
        case .boost: head = "boost"
        }
        var parts = [head, s.lastReason]
        switch (s.intent, s.holder) {
        case (.system, .apple):
            if let die = s.die {
                parts.append("\(s.dieSource) \(degrees(die))\(hottest(of: s.dieSensors))")
            }
            parts.append(rpm(s.fans))
        case (.curve(let curve), .chill):
            if let die = s.die {
                parts.append("\(degrees(die)) → \(Int(curve.rpm(at: die).rounded())) rpm")
            }
            if let presence = s.presence { parts.append("via \(presence.name)") }
            parts.append(rpm(s.fans))
        case (.boost(let until), .chill):
            parts[1] += " for \(remaining(until)) more"
            parts.append(rpm(s.fans))
        case (.curve, .apple):
            if let die = s.die {
                parts.append("\(s.dieSource) \(degrees(die))\(hottest(of: s.dieSensors))")
            }
            parts.append(rpm(s.fans))
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    static func degrees(_ c: Double) -> String { "\(Int(c.rounded()))°C" }

    /// Says the die is a max over N sensors, never a mean; silent for one.
    static func hottest(of sensors: Int) -> String {
        sensors > 1 ? " (hottest of \(sensors))" : ""
    }

    static func rpm(_ fans: [FanState]) -> String {
        fans.map { String(Int($0.actual.rounded())) }.joined(separator: " · ") + " rpm"
    }

    static func points(_ curve: Curve) -> String {
        curve.points.map { "\(degrees($0.c)) \(Int($0.rpm))" }.joined(separator: " · ")
    }

    static func remaining(_ until: Date) -> String {
        let total = max(0, Int(until.timeIntervalSinceNow.rounded()))
        return total >= 60 ? "\(total / 60)m\(total % 60)s" : "\(total)s"
    }
}
