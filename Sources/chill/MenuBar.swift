import AppKit
import ChillKit
import Keymap
import Observation
import ServiceManagement
import SwiftUI

/// The status item: the effect glyph, a left-click menu that leads with
/// whatever fixes a missing daemon, a right-click that toggles system ↔
/// the last curve. The menu is rebuilt on every open from the model, and
/// every item wears its registry key.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let model: Model
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var glyph: Glyph?

    init(model: Model) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        precondition(item.button != nil, "no status bar button")
        menu.delegate = self
        // No permanent statusItem.menu: the click decides. Left = the menu
        // (attached for the click, then detached so the action keeps
        // firing), right = the toggle.
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
        item.menu = menu
        item.button!.performClick(nil)
        item.menu = nil
    }

    // MARK: - the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(model.statusLine, enabled: false)
        if let notice = model.notice { add(notice, enabled: false) }
        if let held = model.heldBy {
            add("held by \(held.name) (pid \(held.pid))", enabled: false)
        }
        switch model.link {
        case .live?: break
        case .bare?: menu.addItem(.separator())
        case .down?, nil:
            menu.addItem(.separator())
            fixer()
        }
        menu.addItem(.separator())
        for (index, curve) in model.curves.enumerated() {
            let entry = add(curve.name, #selector(useCurve(_:)), represented: curve.name)
            entry.state = model.intentCurve == curve.name ? .on : .off
            if index < 9 {
                entry.keyEquivalent = String(index + 1)
                entry.keyEquivalentModifierMask = flags(model.store.familyModifier("curve", .local))
            }
        }
        if model.curves.isEmpty { add("no curves: draw one on the canvas", enabled: false) }
        menu.addItem(.separator())
        add(.boost, #selector(boost))
        add(.system, #selector(system))
        if model.heldBy != nil { add(.takeOver, #selector(takeOver)) }
        menu.addItem(.separator())
        add(.canvas, #selector(canvas))
        add(.help, #selector(help))
        menu.addItem(.separator())
        add(.quit, #selector(quit))
    }

    /// The one action that gets a daemon answering, first.
    private func fixer() {
        switch model.registration {
        case .notRegistered:
            add("install chilld", #selector(install))
        case .requiresApproval:
            if MenuBar.isAdmin {
                add("approve chilld in \(Wire.approvalPath)", #selector(approve))
            } else {
                add("approval is an admin's act: ask one to allow chilld", enabled: false)
                add("open \(Wire.approvalPath)", #selector(approve))
            }
        case .notFound:
            add("no chilld in this bundle (a bare build): mise run install", enabled: false)
        case .enabled:
            add("chilld is registered and not answering: chill daemon status", enabled: false)
        @unknown default:
            add("chilld registration status \(model.registration.rawValue)", enabled: false)
        }
    }

    @discardableResult
    private func add(
        _ title: String, _ selector: Selector? = nil, represented: Any? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.representedObject = represented
        entry.isEnabled = enabled && selector != nil
        menu.addItem(entry)
        return entry
    }

    /// A registry action as a menu item, its live key shown.
    private func add(_ action: ChillAction, _ selector: Selector) {
        let entry = add(action.spec.title, selector)
        guard let combo = model.store.menuCombo(for: action), combo.key.count == 1 else { return }
        entry.keyEquivalent = combo.key
        entry.keyEquivalentModifierMask = flags(combo.eventModifiers)
    }

    private func flags(_ modifiers: SwiftUI.EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    // MARK: - selectors

    @objc private func useCurve(_ sender: NSMenuItem) {
        let name = sender.representedObject as! String
        guard let curve = model.curves.first(where: { $0.name == name }) else { return }
        model.cursor = name
        model.use(curve)
    }

    @objc private func boost() { model.perform(.boost) }
    @objc private func system() { model.perform(.system) }
    @objc private func takeOver() { model.perform(.takeOver) }
    @objc private func canvas() { model.perform(.canvas) }
    @objc private func help() { model.perform(.help) }
    @objc private func quit() { model.perform(.quit) }
    @objc private func install() { model.installDaemon() }
    @objc private func approve() { model.approveDaemon() }

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
