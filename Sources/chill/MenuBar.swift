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
            model.toggle()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // An accessory app owns no key window until it activates; the
        // keys route only into a key popover.
        NSApp.activate()
        popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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

/// The popover: the one switch (Apple ↔ chill), the status, the fixer
/// when no daemon answers, the plot, the two knobs that shape the
/// built-in curve, the actions. Same model, same keys as the canvas.
struct PopoverView: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: .inkLane) {
            HStack(spacing: .inkLane) {
                Picker("", selection: holds) {
                    Text("apple").tag(false)
                    Text("chill").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .disabled(model.state == nil)
                if model.demo.on {
                    Text("demo").font(.meta).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                ActionBar(model: model, popover: true)
            }
            Text(model.statusLine)
                .font(.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let aside = model.aside {
                Text(aside).font(.meta).foregroundStyle(tone.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Fixer(model: model)
            Plot(model: model, curve: model.tuned, editable: false)
                .frame(height: 200)
            Knobs(model: model)
        }
        .padding(.inkBlock)
        .frame(width: 460)
    }

    private var holds: Binding<Bool> {
        Binding(get: { model.holdsFans }, set: { model.hold($0) })
    }
}

/// The two knobs of the built-in curve: where it kicks in, how steep it
/// climbs. Live: every move lands on disk and, when chill runs this
/// curve, on the daemon. A custom curve under the cursor is said so.
struct Knobs: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: .inkGap) {
            HStack(spacing: .inkLane) {
                Text("kicks in at \(Int(model.config.kickIn)) °C")
                    .font(.meta).foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Slider(value: kickIn, in: Config.kickInRange, step: 1)
            }
            HStack(spacing: .inkLane) {
                Text("aggression")
                    .font(.meta).foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Slider(value: aggression, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("gentle").font(.meta).foregroundStyle(.tertiary)
                } maximumValueLabel: {
                    Text("steep").font(.meta).foregroundStyle(.tertiary)
                }
            }
            if let custom = model.intentCurve, custom != Model.tunedName {
                Text(
                    "running your curve \"\(custom)\" from the canvas; the switch returns to this one"
                )
                .font(.meta).foregroundStyle(.tertiary)
            }
        }
        .disabled(model.envelope == nil)
    }

    private var kickIn: Binding<Double> {
        Binding(
            get: { model.config.kickIn },
            set: { model.retune(kickIn: $0, aggression: model.config.aggression) })
    }
    private var aggression: Binding<Double> {
        Binding(
            get: { model.config.aggression },
            set: { model.retune(kickIn: model.config.kickIn, aggression: $0) })
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

/// Every action the surface offers, as a button wearing its live key.
/// The pointer's path and the keyboard's are the same registry entry.
struct ActionBar: View {
    let model: Model
    let popover: Bool

    var body: some View {
        HStack(spacing: .inkGap) {
            if popover {
                button(.boost, "boost")
                if model.heldBy != nil { button(.takeOver, "take over") }
                button(.canvas, "curves")
                button(.help, "?")
                button(.quit, "quit")
            } else {
                button(.newCurve, "new curve")
                if model.editing != nil { button(.useCurve, "use") }
                button(.boost, "boost")
                button(.system, "apple")
                if model.heldBy != nil { button(.takeOver, "take over") }
                Spacer(minLength: 0)
                button(.help, "?")
            }
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
