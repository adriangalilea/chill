import AppKit
import ChillKit
import Ink
import Keymap
import Observation
import ServiceManagement
import SwiftUI

/// The status item: the effect glyph, a left-click popover that IS the
/// product (the tab rail, the plot, the tab's foot, and whatever fixes
/// a missing daemon first), a right-click that opens the app menu.
@MainActor
final class MenuBar: NSObject, NSPopoverDelegate {
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
        popover.delegate = self
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
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
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

    /// The plot lives only while the popover is up.
    func popoverWillShow(_ notification: Notification) { model.popoverShown = true }
    func popoverDidClose(_ notification: Notification) { model.popoverShown = false }

    // MARK: - the app menu (right-click)

    /// What the popover is not for: the app itself. Version and daemon,
    /// the lab, the one shortcut (shown with its live combo, remapped in
    /// its panel), start at login, about, quit. Rebuilt on every open
    /// from the live state. No item for what does not exist yet (an
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
        // One line while the daemon answers (the handshake makes both
        // versions the same one); the daemon's trouble gets its own line.
        if case .live? = model.link {
            _ = add("chill \(Wire.version) · daemon pid \(model.hello?.pid ?? 0)", nil)
        } else {
            _ = add("chill \(Wire.version)", nil)
            _ = add(model.daemonLine, nil)
        }
        menu.addItem(.separator())
        _ = add(ChillAction.canvas.spec.title, #selector(canvas))
        menu.addItem(.separator())
        _ = add("shortcut · \(model.store.displayPrimary(for: .toggle))", #selector(keys))
        let login = add("start at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = add("about", #selector(about))
        menu.addItem(.separator())
        _ = add("quit", #selector(quit), key: "q")
        return menu
    }

    @objc private func canvas() { model.perform(.canvas) }
    @objc private func quit() { model.perform(.quit) }
    @objc private func toggleLogin() { model.toggleLogin() }
    @objc private func keys() { model.showKeys = true }
    @objc private func about() { model.showAbout = true }

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
/// (the built-in curve and its knob), one per custom curve, `+` beside
/// the rail for a new one; picking a tab sends it, the selected tab is
/// what the daemon runs; the tab the toggle would press wears the key
/// mark that says the shortcut. Under them a notice when there is one,
/// the fixer when no daemon answers, the tab's plot, and a foot of one
/// height.
struct PopoverView: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: .inkLane) {
            Tabs(model: model)
            if let aside = model.aside {
                HStack(spacing: .inkLane) {
                    Text(aside).font(.meta).foregroundStyle(tone.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    if model.heldBy != nil {
                        Chip(tint: tone, action: { model.perform(.takeOver) }) {
                            Text("take over").font(.meta)
                        }
                    }
                }
            }
            Fixer(model: model)
            // The plot only while the popover is up (`popoverShown`):
            // hidden, its animations and Canvas would keep drawing at the
            // display's rate. Its space is held so the layout is the same
            // the instant it appears.
            ZStack {
                if model.popoverShown {
                    Plot(model: model, curve: plotted, editable: editable)
                }
            }
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
                        Chip(action: { model.perform(.deleteCurve) }) {
                            HStack(spacing: .inkTight) {
                                Text("trash").font(.system(size: 12))
                                ShortcutBadge(key(.deleteCurve))
                            }
                        }
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
            Text(second).font(.meta).foregroundStyle(.tertiary).lineLimit(1).frame(height: 16)
        }
    }
}

/// The tab bar: one rail holding every intent, `apple · chill | <yours>`,
/// plus `+` while the rail has room for another; the selected segment
/// is a dune plate that slides to whichever the daemon runs.
struct Tabs: View {
    let model: Model
    @Namespace private var rail
    /// The one tip: the shortcut, under the key mark of the tab the
    /// toggle would press. Nothing else on the rail says anything.
    @SwiftUI.State private var tip: Tip?

    var body: some View {
        HStack(spacing: .inkGap) {
            HStack(spacing: 2) {
                // The house's two, each with its glyph, then a hairline,
                // then yours by name.
                cell("apple", .apple, glyph: "apple.logo")
                cell("chill", .tuned, glyph: "snowflake")
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 3)
                ForEach(model.customCurves, id: \.name) { curve in
                    cell(curve.name, .custom(curve.name), glyph: "hand.draw")
                }
            }
            .padding(Tabs.railPadding)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: .inkField))
            .overlay(
                RoundedRectangle(cornerRadius: .inkField)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            // `+` beside the rail, not in it: the rail holds what runs,
            // this makes a new one. The rail's height, so the two align.
            if model.customCurves.count < Model.maxCustom {
                RailButton {
                    model.newCurveTab()
                } label: {
                    Text("+").font(.system(size: 15, weight: .medium))
                }
            }
            if model.demo.on {
                Text("demo").font(.meta).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .coordinateSpace(.named(Tabs.space))
        // The tip: one view for the whole rail, on the pinboard so it
        // stays inside the popover's width whatever it says, below the
        // tab it is about, instant, gone when the pointer leaves.
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                Pinboard {
                    if let tip {
                        TipView(
                            tip: tip, hover: { settle(tip: $0) },
                            gotIt: {
                                model.dismissKeyHint()
                                self.tip = nil
                            }
                        )
                        .pinned { _ in CGPoint(x: tip.at.minX, y: Tabs.railHeight + .inkGap) }
                        .transition(.opacity)
                    }
                }
                .frame(width: proxy.size.width, height: Tabs.railHeight + 120)
            }
        }
        .zIndex(1)
        .disabled(model.state == nil)
        .onChange(of: model.state == nil) { _, off in
            log.info("tabs \(off ? "disabled: link not live" : "enabled", privacy: .public)")
        }
        .animation(.inkSettle, value: model.tab)
        .animation(.inkSettle, value: tip)
    }

    private func cell(_ name: String, _ tab: Model.Tab, glyph: String) -> some View {
        let key = model.store.displayPrimary(for: .toggle)
        return TabCell(
            model: model, name: name, tab: tab, glyph: glyph, rail: rail,
            mark: model.toggleTarget == tab && !key.isEmpty && !model.config.keyHintDismissed
        ) { on, at in
            overDot = on
            if on { tip = Tip(key: key, at: at) }
            settle(tip: overTip)
        }
    }

    /// The tip has a button, so it stays while the pointer is on the
    /// dot or on the tip itself, and closes a beat after it left both:
    /// long enough to cross the gap between them.
    @SwiftUI.State private var overDot = false
    @SwiftUI.State private var overTip = false
    @SwiftUI.State private var closing: Task<Void, Never>?

    private func settle(tip over: Bool) {
        overTip = over
        closing?.cancel()
        guard !overDot, !overTip else { return }
        closing = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, !overDot, !overTip else { return }
            tip = nil
        }
    }

    nonisolated static let cellHeight: CGFloat = 26
    nonisolated static let railPadding: CGFloat = 3
    /// A cell plus the rail's padding: what stands beside the rail is
    /// this tall.
    nonisolated static var railHeight: CGFloat { cellHeight + railPadding * 2 }
    /// The rail's coordinate space, the one cells report their frames in.
    nonisolated static let space = "rail"
}

/// The one thing the rail says, under the key mark: the shortcut, and
/// where (the cell's frame in the rail's space, the tip's anchor).
struct Tip: Equatable {
    let key: String
    let at: CGRect
}

/// The tip itself: the combo as a key cap, what it does, and "got it",
/// which retires the dot and the tip for good. On a plate in the
/// window's background, hugging its content.
struct TipView: View {
    let tip: Tip
    let hover: (Bool) -> Void
    let gotIt: () -> Void

    var body: some View {
        HStack(spacing: .inkLane) {
            HStack(spacing: .inkGap) {
                ShortcutBadge(tip.key)
                Text("toggle from any app").font(.meta).foregroundStyle(.secondary)
            }
            Chip(tint: Palette.dune, action: gotIt) {
                HStack(spacing: .inkTight) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text("got it").font(.meta)
                }
            }
        }
        .fixedSize()
        .padding(.inkLane)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.95),
            in: RoundedRectangle(cornerRadius: .inkRow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .inkRow)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

/// One tab: glyph and name, the dune plate under the one that runs
/// (matched across the rail, so it slides), a wash under the pointer,
/// the text stepping up from secondary to primary on hover and to dune
/// when selected, and a small give on press. Alive, never loud. The
/// tab the toggle would press wears a key mark in its corner, the one
/// hover that says anything: over it, the combo. Reported up with the
/// cell's frame; the rail draws the tip.
struct TabCell: View {
    let model: Model
    let name: String
    let tab: Model.Tab
    let glyph: String
    let rail: Namespace.ID
    let mark: Bool
    let hover: (Bool, CGRect) -> Void
    @SwiftUI.State private var hovering = false
    @SwiftUI.State private var frame = CGRect.zero

    var body: some View {
        let selected = model.tab == tab
        Button {
            model.select(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: glyph).font(.system(size: 11, weight: .medium))
                Text(name)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, .inkLane)
            .frame(height: Tabs.cellHeight)
            .overlay(alignment: .topTrailing) {
                if mark {
                    // A dune dot in the cell's corner, in the padding, so
                    // nothing moves: the one dot in the app that carries
                    // meaning, the tip under it says the shortcut. Static.
                    Circle()
                        .fill(Palette.dune)
                        .frame(width: 6, height: 6)
                        .padding(3)
                        .contentShape(Rectangle())
                        .onHover { hover($0, frame) }
                }
            }
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: .inkRow)
                        .fill(Palette.dune.opacity(0.22))
                        .matchedGeometryEffect(id: "plate", in: rail)
                } else if hovering {
                    RoundedRectangle(cornerRadius: .inkRow)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Give())
        .foregroundStyle(selected ? Palette.dune : hovering ? .primary : .secondary)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Tabs.space))
        } action: {
            frame = $0
        }
        .onHover { hovering = $0 }
        .animation(.inkSettle, value: hovering)
    }
}

/// A square button the rail's height, beside it: the same wash on
/// hover, the same give on press.
struct RailButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(width: Tabs.railHeight, height: Tabs.railHeight)
                .background(
                    Color.primary.opacity(hovering ? 0.12 : 0.06),
                    in: RoundedRectangle(cornerRadius: .inkField)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .inkField)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(Give())
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .animation(.inkSettle, value: hovering)
    }
}

/// THE button of the popover and its panels, every one the same: a
/// faint plate with a hairline, a wash under the pointer, secondary ink
/// stepping up to primary on hover (or a tint), and the give on press.
struct Chip<Label: View>: View {
    var tint: Color? = nil
    let action: () -> Void
    @ViewBuilder let label: Label
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, .inkGap)
                .padding(.vertical, .inkTight)
                .background(
                    Color.primary.opacity(hovering ? 0.12 : 0.06),
                    in: RoundedRectangle(cornerRadius: .inkRow)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .inkRow)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(Give())
        .foregroundStyle(ink)
        .onHover { hovering = $0 }
        .animation(.inkSettle, value: hovering)
    }

    private var ink: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint.opacity(hovering ? 1 : 0.85)) }
        return hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

/// The press: a slight give and a dip, back on release.
struct Give: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
            : "floor until \(Int(first.c)) °C, full at \(Int(last.c)) °C"
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
            Chip(tint: tone, action: { model.perform(.quit) }) {
                Text("this chill is older than chilld: quit and relaunch chill.app")
                    .font(.system(size: 12))
            }
        case .bare?, .down?, nil:
            registration
        }
    }

    @ViewBuilder private var registration: some View {
        switch model.registration {
        case .notRegistered:
            Chip(tint: tone, action: { model.installDaemon() }) {
                Text("install chilld").font(.system(size: 12))
            }
        case .requiresApproval:
            if MenuBar.isAdmin {
                Chip(tint: tone, action: { model.approveDaemon() }) {
                    Text("approve chilld in \(Wire.approvalPath)").font(.system(size: 12))
                }
            } else {
                Text("approval is an admin's act: ask one to allow chilld")
                    .font(.meta).foregroundStyle(.secondary)
                Chip(tint: tone, action: { model.approveDaemon() }) {
                    Text("open \(Wire.approvalPath)").font(.system(size: 12))
                }
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
        }
    }

    private func button(_ action: ChillAction, _ short: String) -> some View {
        let key = model.store.displayPrimary(for: action)
        return Chip(action: { model.perform(action) }) {
            HStack(spacing: .inkTight) {
                Text(short).font(.system(size: 12))
                if !key.isEmpty { ShortcutBadge(key) }
            }
            .fixedSize()
        }
        .help(action.spec.title)
    }
}

/// The one shortcut and its recorder, on the floating glass: Keymap's
/// grid for the toggle alone, which warns live when macOS or another app
/// owns the combo. The popover's keys (⌘N, ⌘⌫, ⎋, ⌘Q) are what every
/// Mac app has and are shown where they act, so they are not here.
struct KeysPanel: View {
    static let size = NSSize(width: 460, height: 220)
    let store: KeymapStore<ChillAction>
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: .inkLane) {
            Text("shortcut")
                .font(.system(size: 16, weight: .semibold))
            Text("from any app: Apple's curve if yours runs, yours if Apple's does")
                .font(.meta)
                .foregroundStyle(.secondary)
            KeymapGrid(store: store, sections: ChillAction.shortcutSections)
            Spacer(minLength: 0)
        }
        .padding(.inkBlock)
        .frame(width: KeysPanel.size.width, height: KeysPanel.size.height, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            CloseButton(close: close)
        }
    }
}

/// The floating panels' close: a small circled x, top right.
struct CloseButton: View {
    let close: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(hovering ? 0.12 : 0.06), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(Give())
        .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .onHover { hovering = $0 }
        .animation(.inkSettle, value: hovering)
        .padding(.inkLane)
    }
}

/// About, on the same glass as the cheat sheet: the icon, the name, the
/// version, the credits README carries. Not AppKit's standard panel: an
/// accessory app opened from its status item is not granted activation,
/// so that panel comes up behind the front window, unseen.
struct AboutPanel: View {
    static let size = NSSize(width: 400, height: 420)
    let close: () -> Void

    var body: some View {
        VStack(spacing: .inkLane) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("chill")
                .font(.system(size: 20, weight: .semibold))
            Text(Wire.version)
                .font(.meta)
                .foregroundStyle(.tertiary)
            Text(Model.credits)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.inkBlock)
        .padding(.top, .inkLane)
        .frame(width: AboutPanel.size.width, height: AboutPanel.size.height)
        .overlay(alignment: .topTrailing) {
            CloseButton(close: close)
        }
    }
}
