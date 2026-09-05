import ChillKit
import Foundation
import IOKit
import IOKit.pwr_mgt

enum PowerWatchError: Error, CustomStringConvertible {
    case noRootDomain
    case registerFailed
    case interest(kern_return_t)

    var description: String {
        switch self {
        case .noRootDomain: return "power: no IOPMrootDomain service"
        case .registerFailed: return "power: IORegisterForSystemPower failed"
        case .interest(let rc):
            return "power: IOServiceAddInterestNotification failed, \(String(rc, radix: 16))"
        }
    }
}

/// The IOKit power messages, composed as IOMessage.h and IOPM.h compose
/// them (`iokit_common_msg` / `iokit_family_msg` are function-like macros
/// Swift does not import): `sys_iokit` = `err_system(0x38)` = 0x38 << 26,
/// `sub_iokit_common` = 0, `sub_iokit_powermanagement` = `err_sub(13)` =
/// 13 << 14, or-ed with the message number.
enum PowerMessage {
    private static let sysIOKit: UInt32 = 0x38 << 26
    private static let subPowerManagement: UInt32 = 13 << 14

    static let canSystemSleep: UInt32 = sysIOKit | 0x270
    static let systemWillSleep: UInt32 = sysIOKit | 0x280
    static let systemHasPoweredOn: UInt32 = sysIOKit | 0x300
    static let clamshellStateChange: UInt32 = sysIOKit | subPowerManagement | 0x100
}

/// The sleep and lid nets, both from IOPMrootDomain on the daemon's own
/// serial queue. Sleep: `IORegisterForSystemPower`; `kIOMessageCanSystemSleep`
/// is acknowledged at once, `kIOMessageSystemWillSleep` runs the engine's
/// hand-back to completion and THEN acknowledges (a missing ack delays
/// every sleep 30 s), `kIOMessageSystemHasPoweredOn` re-reads the lid and
/// tells the engine. Lid: a general-interest notification on the same
/// service delivers `kIOPMMessageClamshellStateChange`, bit 0 = closed;
/// the initial value is the `AppleClamshellState` property, absent on a
/// Mac without a lid. Every delivery reaches the engine through
/// `blocking` on this queue, so the engine sees them in the order IOKit
/// sent them: unstructured tasks aimed at one actor keep no order, and a
/// wake with the lid closed followed by the clamshell opening must not
/// land reversed.
final class PowerWatch {
    let hasLid: Bool
    private let engine: Engine
    private let rootDomain: io_service_t
    private var port: IONotificationPortRef?
    private var connect: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var lidNotifier: io_object_t = 0

    init(engine: Engine) throws {
        self.engine = engine
        rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { throw PowerWatchError.noRootDomain }
        hasLid = PowerWatch.clamshell(rootDomain) != nil
        Log.notice(
            hasLid
                ? "lid: AppleClamshellState \(lidClosed! ? "closed" : "open")"
                : "lid: no clamshell on this Mac, no lid veto")
    }

    /// The lid as IOPMrootDomain reports it right now; nil without a lid.
    var lidClosed: Bool? { PowerWatch.clamshell(rootDomain) }

    /// Register both notifications, delivered on `queue`. Separate from
    /// `init` because the callbacks carry `self` as their refcon.
    func start(on queue: DispatchQueue) throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        connect = IORegisterForSystemPower(refcon, &port, powerCallback, &powerNotifier)
        guard connect != 0, let port else { throw PowerWatchError.registerFailed }
        IONotificationPortSetDispatchQueue(port, queue)
        let rc = IOServiceAddInterestNotification(
            port, rootDomain, kIOGeneralInterest, lidCallback, refcon, &lidNotifier)
        guard rc == KERN_SUCCESS else { throw PowerWatchError.interest(rc) }
        Log.notice("power: watching sleep and the lid")
    }

    fileprivate func power(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch message {
        case PowerMessage.canSystemSleep:
            allow(argument)
        case PowerMessage.systemWillSleep:
            Log.notice("power: system will sleep")
            blocking { [engine] in await engine.willSleep() }
            allow(argument)
        case PowerMessage.systemHasPoweredOn:
            let closed = lidClosed
            blocking { [engine] in await engine.poweredOn(lidClosed: closed) }
        default:
            break
        }
    }

    fileprivate func lid(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        guard message == PowerMessage.clamshellStateChange else { return }
        let closed = UInt(bitPattern: argument) & UInt(kClamshellStateBit) != 0
        Log.notice("lid: \(closed ? "closed" : "open")")
        blocking { [engine] in await engine.lid(closed: closed) }
    }

    private func allow(_ argument: UnsafeMutableRawPointer?) {
        let rc = IOAllowPowerChange(connect, Int(bitPattern: argument))
        if rc != kIOReturnSuccess {
            Log.error("power: IOAllowPowerChange failed, \(String(rc, radix: 16))")
        }
    }

    private static func clamshell(_ root: io_service_t) -> Bool? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                root, kAppleClamshellStateKey as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        let closed = value.takeRetainedValue() as? Bool
        precondition(closed != nil, "AppleClamshellState is not a boolean")
        return closed
    }
}

private let powerCallback: IOServiceInterestCallback = { refcon, _, message, argument in
    Unmanaged<PowerWatch>.fromOpaque(refcon!).takeUnretainedValue().power(message, argument)
}

private let lidCallback: IOServiceInterestCallback = { refcon, _, message, argument in
    Unmanaged<PowerWatch>.fromOpaque(refcon!).takeUnretainedValue().lid(message, argument)
}
