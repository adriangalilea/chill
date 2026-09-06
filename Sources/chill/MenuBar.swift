import AppKit
import ChillKit
import Ink
import Keymap
import Observation
import ServiceManagement
import SwiftUI

/// The status item: the effect glyph, a left-click popover that IS the
/// product (the plot over Apple's cloud, the curves, the actions with
/// their keys, and whatever fixes a missing daemon first), a right-click
/// that toggles system ↔ the last curve.
@MainActor
final class MenuBar: NSObject {
    private let model: Model
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var glyph: Glyph?

    init(model: Model) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        precondition(item.button != nil, "no status bar button")
        popover.behavior = .transient
        popover.animates = false
        let hosting = NSHostingController(rootView: PopoverView(model: model))
        // The popover takes SwiftUI's ideal size, not the first guess:
        // without this the top row is measured short and clipped.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        model.popover = popover
        item.button!.target = self
        item.button!.action = #selector(clicked)
        item.button!.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observe()
    }

    /// Re-render on every model change: observation tracking re-arms
    /// itself after each mutation it saw.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func render() {
        let next = Glyph(model.link)
        if next != glyph {
            glyph = next
            item.button!.image = next.image()
        }
        item.button!.toolTip = model.statusLine
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            log.info("right-click: the app menu")
            item.menu = appMenu()
            item.button!.performClick(nil)
            item.menu = nil
            return
        }
        if popover.isShown {
            log.info("popover closed by the status item")
            popover.performClose(nil)
            return
        }
        log.info("popover opened; \(self.model.statusLine, privacy: .public)")
        // An accessory app owns no key window until it activates; the
        // keys route only into a key popover.
        NSApp.activate()
        popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
        // Activation is cooperative and lands a turn later; the popover's
        // window must be key for the keys to route into it, so it is
        // made key after that turn, and the trace says whether it took.
        DispatchQueue.main.async { [popover] in
            guard let window = popover.contentViewController?.view.window else {
                log.error("popover shown without a window")
                return
            }
            window.makeKeyAndOrderFront(nil)
            log.info(
                "popover window key: \(window.isKeyWindow, privacy: .public), app active: \(NSApp.isActive, privacy: .public)"
            )
        }
    }

    // MARK: - the app menu (right-click)

    /// What the popover is not for: the app itself. Version, daemon state,
    /// the canvas, the keys, start at login, about, quit. Rebuilt on every
    /// open from the live state. No item for what does not exist yet (an
    /// update check comes with the appcast).
    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector?, key: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            entry.target = self
            entry.isEnabled = selector != nil
            menu.addItem(entry)
            return entry
        }
        _ = add("chill \(Wire.version)", nil)
        _ = add(model.daemonLine, nil)
        menu.addItem(.separator())
        _ = add("canvas", #selector(canvas), key: "c")
        _ = add("shortcuts", #selector(help), key: "?")
        menu.addItem(.separator())
        let login = add("start at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add("about chill", #selector(about))
        menu.addItem(.separator())
        _ = add("quit chill", #selector(quit), key: "q")
        return menu
    }

    @objc private func canvas() { model.perform(.canvas) }
    @objc private func help() { model.perform(.help) }
    @objc private func quit() { model.perform(.quit) }
    @objc private func toggleLogin() { model.toggleLogin() }
    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "chill",
            .applicationVersion: Wire.version,
            .credits: NSAttributedString(
                string: Model.credits,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]),
        ])
    }

    /// Membership of the `admin` group, the one that can approve a
    /// LaunchDaemon in System Settings. The group and the current user
    /// always exist on macOS; a lookup that fails is a broken world, not
    /// a standard user.
    static var isAdmin: Bool {
        guard let admin = getgrnam("admin") else { preconditionFailure("no admin group") }
        guard let user = getpwuid(getuid()) else { preconditionFailure("no passwd entry for uid") }
        var count: Int32 = 64
        var groups = [gid_t](repeating: 0, count: Int(count))
        let rc = groups.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                getgrouplist(user.pointee.pw_name, Int32(user.pointee.pw_gid), $0, &count)
            }
        }
        precondition(rc >= 0, "getgrouplist overflowed \(groups.count) groups")
        return groups.prefix(Int(count)).contains(admin.pointee.gr_gid)
    }
}

/// The popover. Tabs across the top ARE the intents: `apple`, `chill`
/// (the built-in curve and its two knobs), one per custom curve, `+`
/// for a new one; picking a tab sends it, the selected tab is what the
/// daemon runs. Right of the tabs: boost and `?`. Under them the status,
/// the fixer when no daemon answers, and the tab's plot.
struct PopoverView: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: .inkLane) {
            Tabs(model: model)
            if let aside = model.aside {
                Text(aside).font(.meta).foregroundStyle(tone.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Fixer(model: model)
            Plot(model: model, curve: plotted, editable: editable)
                .frame(height: 200)
                .onChange(of: model.tab, initial: true) { _, tab in
                    if case .custom(let name) = tab { model.cursor = name }
                }
            // The foot is the same height on every tab, so the popover
            // never resizes and the plot never moves: the knobs' height,
            // with the other tabs' content or nothing in that space.
            ZStack(alignment: .topLeading) {
                switch model.tab {
                case .apple:
                    Foot(first: vetoNote, second: model.partsLine)
                        .transition(.opacity)
                case .gust:
                    Foot(first: gustLine + vetoNote, second: model.partsLine)
                        .transition(.opacity)
                case .tuned:
                    Knobs(model: model).transition(.opacity)
                case .custom:
                    HStack(spacing: .inkLane) {
                        Text("press the line to add a point and drag it · right-click removes one")
                            .font(.meta).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        Button {
                            model.perform(.deleteCurve)
                        } label: {
                            HStack(spacing: .inkTight) {
                                Text("trash").font(.system(size: 12))
                                ShortcutBadge(key(.deleteCurve))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: PopoverView.footHeight)
        }
        .padding(.inkBlock)
        .frame(width: 460)
        .animation(.inkSettle, value: model.tab)
    }

    /// Two knob rows at 16 pt and their gap.
    static let footHeight: CGFloat = 16 * 2 + .inkGap

    /// A CLI boost's own clock, from the daemon's intent.
    private var gustLine: String {
        if case .boost(let until)? = model.state?.intent {
            return "boost from the cli · \(Status.remaining(until)) left, then apple · "
        }
        return ""
    }

    /// A veto in force is the one thing worth saying on any tab.
    private var vetoNote: String {
        guard let vetoes = model.state?.vetoes, !vetoes.isEmpty else { return "" }
        return "vetoed: " + vetoes.map(\.rawValue).joined(separator: ", ")
            + " · apple holds the fans"
    }

    /// What the plot draws for the tab: nothing over Apple's cloud, the
    /// built-in curve, the custom curve, or the ceiling during a gust.
    private var plotted: Curve? {
        switch model.tab {
        case .apple: return nil
        case .tuned: return model.tuned
        case .custom(let name): return model.curves.first { $0.name == name }
        case .gust:
            return model.envelope.flatMap { try? Curve.flat(name: "gust", rpm: $0.upperBound) }
        }
    }

    private var editable: Bool {
        if case .custom = model.tab { return true }
        return false
    }

    private func key(_ action: ChillAction) -> String { model.store.displayPrimary(for: action) }
}

/// The foot of the apple and gust tabs: two mono lines in the knobs'
/// space, what the plot cannot say at a glance.
struct Foot: View {
    let first: String
    let second: String

    var body: some View {
        VStack(alignment: .leading, spacing: .inkGap) {
            Text(first).font(.meta).foregroundStyle(.secondary).frame(height: 16)
            Text(second).font(.meta).foregroundStyle(.tertiary).frame(height: 16)
        }
    }
}

/// The tab bar: one rail holding every intent, `apple · chill · <custom>
/// · gust`, plus `+`; the selected segment is a dune plate that slides
/// to whichever the daemon runs. `?` sits apart on the right.
struct Tabs: View {
    let model: Model
    @Namespace private var rail

    var body: some View {
        HStack(spacing: .inkGap) {
            HStack(spacing: 2) {
                // The house's three, each with its glyph, then a hairline,
                // then yours by name.
                tab("apple", .apple, glyph: "apple.logo")
                tab("chill", .tuned, glyph: "snowflake")
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 3)
                ForEach(model.customCurves, id: \.name) { curve in
                    tab(curve.name, .custom(curve.name), glyph: "hand.draw")
                }
                Button {
                    model.newCurveTab()
                } label: {
                    Text("+").font(.system(size: 14, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("a new curve, born as a copy of chill, yours to draw")
            }
            .padding(3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: .inkField))
            .overlay(
                RoundedRectangle(cornerRadius: .inkField)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            if model.demo.on {
                Text("demo").font(.meta).foregroundStyle(.tertiary)
            }
            Spacer(minLength: .inkLane)
            Button {
                model.perform(.help)
            } label: {
                Text("?").font(.system(size: 12))
                    .frame(width: 26, height: 26)
                    .background(
                        Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: .inkRow)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("every key, and quit")
        }
        .disabled(model.state == nil)
        .onChange(of: model.state == nil) { _, off in
            log.info("tabs \(off ? "disabled: link not live" : "enabled", privacy: .public)")
        }
        .animation(.inkSettle, value: model.tab)
    }

    private func tab(_ name: String, _ tab: Model.Tab, glyph: String?) -> some View {
        let selected = model.tab == tab
        return Button {
            model.select(tab)
        } label: {
            HStack(spacing: 5) {
                if let glyph {
                    Image(systemName: glyph).font(.system(size: 11, weight: .medium))
                }
                Text(name)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, .inkLane)
            .frame(height: 26)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: .inkRow)
                        .fill(Palette.dune.opacity(0.22))
                        .matchedGeometryEffect(id: "plate", in: rail)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Palette.dune : .secondary)
        .help(Tabs.about(tab, name))
    }

    /// What a tab means, on hover: the one place this is said.
    static func about(_ tab: Model.Tab, _ name: String) -> String {
        switch tab {
        case .apple: return "macOS runs the fans; chill only watches"
        case .tuned:
            return
                "the house curve: the fans at their minimum until the chip passes the kick-in, then a smooth climb to full"
        case .gust:
            return "every fan flat out for \(Wire.boostMinutes) minutes, then back to apple"
        case .custom:
            return
                "your curve \"\(name)\": press the line to add a point and drag it, right-click removes one"
        }
    }
}

/// The one knob of the built-in curve: how hard it pushes. The whole
/// curve moves with it, floor, kick-in and climb; the reading says the
/// floor and where the climb starts. Live: every move lands on disk and,
/// while chill runs, on the daemon.
struct Knobs: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: .inkGap) {
            // No reading: the knob picks a curve, and the curve above moves
            // with it; a number here would read as an rpm being chosen.
            Knob(label: "push", value: push, range: 0...1, step: 0.02, reading: "")
            Text(hint).font(.meta).foregroundStyle(.tertiary).frame(height: 16)
        }
        .disabled(model.envelope == nil)
    }

    private var hint: String {
        guard let tuned = model.tuned, let first = tuned.points.first, let last = tuned.points.last
        else { return "" }
        return first.rpm >= last.rpm
            ? "every fan flat out"
            : "floor until \(Int(first.c)) °C, full at \(Int(last.c)) °C · draw your own with +"
    }

    private var push: Binding<Double> {
        Binding(get: { model.config.push }, set: { model.retune(push: $0) })
    }
}

/// The house slider: a hairline track, the run so far in dune, a small
/// knob, the reading in mono at the end. Click anywhere sets, drag
/// follows.
struct Knob: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let reading: String

    var body: some View {
        HStack(spacing: .inkLane) {
            Text(label).font(.meta).foregroundStyle(.secondary)
                .fixedSize()
            GeometryReader { proxy in
                let width = proxy.size.width
                let t =
                    (value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: 2)
                    Capsule().fill(Palette.dune.opacity(0.7)).frame(width: width * t, height: 2)
                    Circle().fill(Palette.dune).frame(width: 10, height: 10)
                        .offset(x: width * t - 5)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        let raw =
                            range.lowerBound
                            + (range.upperBound - range.lowerBound)
                            * min(1, max(0, drag.location.x / width))
                        value.wrappedValue = (raw / step).rounded() * step
                    })
            }
            .frame(height: 16)
            if !reading.isEmpty {
                Text(reading).font(.meta).foregroundStyle(Palette.dune)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

/// The one action that gets a daemon answering, first. A daemon that
/// answered and refused this process for good is fixed by a relaunch,
/// whatever the registration says. A bare build reads `.notFound` (no
/// LaunchDaemons plist beside its executable) and is told what installs
/// one. Renders nothing while the daemon is live.
struct Fixer: View {
    let model: Model

    var body: some View {
        switch model.link {
        case .live?:
            EmptyView()
        case .stale?:
            Button("this chill is older than chilld: quit and relaunch chill.app") {
                model.perform(.quit)
            }
        case .bare?, .down?, nil:
            registration
        }
    }

    @ViewBuilder private var registration: some View {
        switch model.registration {
        case .notRegistered:
            Button("install chilld") { model.installDaemon() }
        case .requiresApproval:
            if MenuBar.isAdmin {
                Button("approve chilld in \(Wire.approvalPath)") { model.approveDaemon() }
            } else {
                Text("approval is an admin's act: ask one to allow chilld")
                    .font(.meta).foregroundStyle(.secondary)
                Button("open \(Wire.approvalPath)") { model.approveDaemon() }
            }
        case .notFound:
            Text("no chilld in this bundle (a bare build): mise run install")
                .font(.meta).foregroundStyle(.secondary)
        case .enabled:
            Text("chilld is registered and not answering: chill daemon status")
                .font(.meta).foregroundStyle(.secondary)
        @unknown default:
            Text("chilld registration status \(model.registration.rawValue)")
                .font(.meta).foregroundStyle(.secondary)
        }
    }
}

/// The canvas window's actions, buttons wearing their live keys. The
/// pointer's path and the keyboard's are the same registry entry.
struct ActionBar: View {
    let model: Model

    var body: some View {
        HStack(spacing: .inkGap) {
            button(.newCurve, "new curve")
            if model.editing != nil { button(.useCurve, "use") }
            button(.system, "apple")
            if model.heldBy != nil { button(.takeOver, "take over") }
            Spacer(minLength: 0)
            button(.help, "?")
        }
    }

    private func button(_ action: ChillAction, _ short: String) -> some View {
        Button {
            model.perform(action)
        } label: {
            HStack(spacing: .inkTight) {
                Text(short).font(.system(size: 12))
                if short != "?" { ShortcutBadge(model.store.displayPrimary(for: action)) }
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, .inkGap)
        .padding(.vertical, .inkTight)
        .background(Color.inkRest.opacity(0.5), in: RoundedRectangle(cornerRadius: .inkRow))
        .help(action.spec.title)
    }
}
