import ChillKit
import Keymap
import SwiftUI

/// THE registry of user-facing actions, on the studio's Keymap spine:
/// identity, title, symbol and default key, once. The status menu shows
/// the live keys, `?` renders the cheat sheet from it, the canvas routes
/// the same combos through `LocalKeyRouter`. Adding an action = one
/// case + one spec + one section + one branch in `Model.perform`; the
/// exhaustive switch is the compiler naming what is missing. The pointer
/// is the fallback: every one of these is reachable from the keyboard.
enum ChillAction: String, CaseIterable, ActionSet {
    case pointUp, pointDown, pointLeft, pointRight, nextPoint, previousPoint, addPoint,
        removePoint
    case previousCurve, nextCurve, useCurve, newCurve, deleteCurve
    case boost, system, takeOver
    case cloud
    case canvas, back, help, quit

    var spec: Spec {
        switch self {
        case .pointUp:
            return Spec(
                title: "point: \(Int(Model.rpmStep)) rpm up", symbol: "arrow.up",
                local: [KeyCombo("up")])
        case .pointDown:
            return Spec(
                title: "point: \(Int(Model.rpmStep)) rpm down", symbol: "arrow.down",
                local: [KeyCombo("down")])
        case .pointLeft:
            return Spec(
                title: "point: \(Int(Model.celsiusStep)) °C cooler", symbol: "arrow.left",
                local: [KeyCombo("left")])
        case .pointRight:
            return Spec(
                title: "point: \(Int(Model.celsiusStep)) °C hotter", symbol: "arrow.right",
                local: [KeyCombo("right")])
        case .nextPoint:
            return Spec(
                title: "next point", symbol: "arrow.right.to.line", local: [KeyCombo("tab")])
        case .previousPoint:
            return Spec(
                title: "previous point", symbol: "arrow.left.to.line",
                local: [KeyCombo("tab", .shift)])
        case .addPoint:
            return Spec(title: "add a point after", symbol: "plus", local: [KeyCombo("n")])
        case .removePoint:
            return Spec(title: "remove the point", symbol: "minus", local: [KeyCombo("delete")])
        case .previousCurve:
            return Spec(title: "curve above", symbol: "chevron.up", local: [KeyCombo("[")])
        case .nextCurve:
            return Spec(title: "curve below", symbol: "chevron.down", local: [KeyCombo("]")])
        case .useCurve:
            return Spec(
                title: "use this curve", symbol: "checkmark", local: [KeyCombo("return")])
        case .newCurve:
            return Spec(
                title: "new curve", symbol: "plus.square", local: [KeyCombo("n", .command)])
        case .deleteCurve:
            return Spec(
                title: "trash this curve", symbol: "trash", local: [KeyCombo("delete", .command)])
        case .boost:
            return Spec(
                title: "gust: every fan at maximum for \(Wire.boostMinutes) min", symbol: "wind",
                local: [KeyCombo("b")])
        case .system:
            return Spec(
                title: "system: Apple's curve", symbol: "apple.logo", local: [KeyCombo("s")])
        case .takeOver:
            return Spec(
                title: "take over from the other watcher", symbol: "hand.raised",
                local: [KeyCombo("t")])
        case .cloud:
            return Spec(
                title: "apple history: where macOS has kept the fans, show or hide",
                symbol: "clock.arrow.circlepath", local: [KeyCombo("a")])
        case .canvas:
            return Spec(title: "canvas", symbol: "chart.xyaxis.line", local: [KeyCombo("c")])
        case .back:
            return Spec(title: "close", symbol: "xmark", local: [KeyCombo("escape")])
        case .help:
            return Spec(title: "shortcuts", symbol: "questionmark.circle", local: [KeyCombo("?")])
        case .quit:
            return Spec(title: "quit", symbol: "power", local: [KeyCombo("q", .command)])
        }
    }

    static var sections: [ActionSection<ChillAction>] {
        [
            ActionSection(
                "point",
                [
                    .pointUp, .pointDown, .pointLeft, .pointRight, .nextPoint, .previousPoint,
                    .addPoint, .removePoint,
                ]),
            ActionSection(
                "curves", [.previousCurve, .nextCurve, .useCurve, .newCurve, .deleteCurve]),
            ActionSection("fans", [.boost, .system, .takeOver]),
            ActionSection("plot", [.cloud]),
            ActionSection("app", [.canvas, .back, .help, .quit]),
        ]
    }

    /// ⌘1 to ⌘9 pick the Nth curve in list order; the digits are the
    /// targets, only the modifier remaps. No global plane: the app installs
    /// no system-wide hotkeys, so an empty modifier reserves nothing.
    static let curveFamily = ComboFamily(
        id: "curve", name: "the numbered curve picks", keys: (1...9).map(String.init),
        localModifier: .command, globalModifier: [])
}
