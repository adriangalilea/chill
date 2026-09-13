import ChillKit
import Foundation
import IOKit
import IOKit.pwr_mgt

enum PowerWatchError: Error, CustomStringConvertible {
    case registerFailed

    var description: String {
        switch self {
        case .registerFailed: return "power: IORegisterForSystemPower failed"
        }
    }
}

/// The IOKit power messages, composed as IOMessage.h composes them
/// (`iokit_common_msg` is a function-like macro Swift does not import):
/// `sys_iokit` = `err_system(0x38)` = 0x38 << 26, `sub_iokit_common` = 0,
/// or-ed with the message number.
enum PowerMessage {
    private static let sysIOKit: UInt32 = 0x38 << 26

    static let canSystemSleep: UInt32 = sysIOKit | 0x270
    static let systemWillSleep: UInt32 = sysIOKit | 0x280
    static let systemHasPoweredOn: UInt32 = sysIOKit | 0x300
}

/// The sleep net, from IOPMrootDomain on the daemon's own serial queue:
/// `IORegisterForSystemPower`; `kIOMessageCanSystemSleep` is acknowledged
/// at once, `kIOMessageSystemWillSleep` runs the engine's hand-back to
/// completion and THEN acknowledges (a missing ack delays every sleep
/// 30 s), `kIOMessageSystemHasPoweredOn` tells the engine. chill never
/// stands in the way of sleep, and that is the whole of what the lid
/// means to it: a closed lid on a Mac that stays awake (docked) is a Mac
/// that stays awake. Every delivery reaches the engine through
/// `blocking` on this queue, so the engine sees them in the order IOKit
/// sent them.
final class PowerWatch {
    private let engine: Engine
    private var port: IONotificationPortRef?
    private var connect: io_connect_t = 0
    private var powerNotifier: io_object_t = 0

    init(engine: Engine) { self.engine = engine }

    /// Register the notification, delivered on `queue`. Separate from
    /// `init` because the callback carries `self` as its refcon.
    func start(on queue: DispatchQueue) throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        connect = IORegisterForSystemPower(refcon, &port, powerCallback, &powerNotifier)
        guard connect != 0, let port else { throw PowerWatchError.registerFailed }
        IONotificationPortSetDispatchQueue(port, queue)
        Log.notice("power: watching sleep")
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
            blocking { [engine] in await engine.poweredOn() }
        default:
            break
        }
    }

    private func allow(_ argument: UnsafeMutableRawPointer?) {
        let rc = IOAllowPowerChange(connect, Int(bitPattern: argument))
        if rc != kIOReturnSuccess {
            Log.error("power: IOAllowPowerChange failed, \(String(rc, radix: 16))")
        }
    }
}

private let powerCallback: IOServiceInterestCallback = { refcon, _, message, argument in
    Unmanaged<PowerWatch>.fromOpaque(refcon!).takeUnretainedValue().power(message, argument)
}
