import ChillKit
import Keymap
import SwiftUI

/// THE registry of user-facing actions, on the studio's Keymap spine:
/// identity, title, symbol and default key, once. chill is a pointer app
/// by decision: the popover is drawn with the mouse, and a key that
/// needs the mouse in hand first is worth nothing. What the keyboard is
/// for here is ONE thing, from anywhere: `toggle`, Apple's curve or
/// yours, the app's identity verb on a heavy chord (the studio's
/// convention for a system-wide default), remappable from the app menu.
/// The rest are the keys every Mac user expects without being told,
/// shown where they act (the trash button's badge) and nowhere else.
/// Adding an action = one case + one spec + one section + one branch in
/// `Model.perform`; the exhaustive switch is the compiler naming what is
/// missing.
enum ChillAction: String, CaseIterable, ActionSet {
    case toggle
    case newCurve, deleteCurve, useCurve
    case system, takeOver
    case canvas, back, quit

    var spec: Spec {
        switch self {
        case .toggle:
            return Spec(
                title: "apple or your curve", symbol: "fan",
                global: [KeyCombo("c", [.control, .option, .command])])
        case .newCurve:
            return Spec(
                title: "new curve", symbol: "plus.square", local: [KeyCombo("n", .command)])
        case .deleteCurve:
            return Spec(
                title: "trash this curve", symbol: "trash", local: [KeyCombo("delete", .command)])
        case .useCurve:
            return Spec(title: "use this curve", symbol: "checkmark")
        case .system:
            return Spec(title: "system: Apple's curve", symbol: "apple.logo")
        case .takeOver:
            return Spec(title: "take the fans over", symbol: "hand.raised")
        case .canvas:
            return Spec(title: "lab", symbol: "flask")
        case .back:
            return Spec(title: "close", symbol: "xmark", local: [KeyCombo("escape")])
        case .quit:
            return Spec(title: "quit", symbol: "power", local: [KeyCombo("q", .command)])
        }
    }

    static var sections: [ActionSection<ChillAction>] {
        [
            ActionSection("fans", [.toggle, .system, .takeOver]),
            ActionSection("curves", [.newCurve, .deleteCurve, .useCurve]),
            ActionSection("app", [.canvas, .back, .quit]),
        ]
    }

    /// The one row the shortcut panel shows: the toggle, system-wide.
    static var shortcutSections: [ActionSection<ChillAction>] {
        [ActionSection("from anywhere", [.toggle])]
    }
}
