import AppKit
import ApplicationServices

final class GlobalHotKeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onPermissionNeeded: (() -> Void)?

    /// The hotkey to watch. Changing this takes effect on the next restart().
    var option: HotKeyOption = AppSettings.shared.hotKeyOption

    // Internal (not private) so the tap callback can re-enable on timeout
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var keyDownTime: Date?
    fileprivate var isKeyDown = false

    private let minHoldMs: Double = 150

    func start() {
        dbg("start() option=\(option.rawValue)")
        attemptStart()
    }

    private func attemptStart() {
        tearDownTap()
        let axTrusted = AXIsProcessTrusted()
        dbg("attemptStart AXIsProcessTrusted=\(axTrusted)")
        guard axTrusted else {
            onPermissionNeeded?()
            scheduleRetry()
            return
        }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: globalHotKeyCallback,
            userInfo: selfPtr
        )
        guard let tap else {
            dbg("tapCreate FAILED — retrying")
            scheduleRetry()
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = src
        dbg("tapCreate SUCCESS")
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
                self.attemptStart()
            }
        }
    }

    private func tearDownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isKeyDown = false
        keyDownTime = nil
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        tearDownTap()
    }

    func restart() {
        stop()
        start()
    }

    // Called from the tap callback (runs on main runloop).
    fileprivate func fireKeyEvent(isDown: Bool) {
        if isDown && !self.isKeyDown {
            self.isKeyDown = true
            self.keyDownTime = Date()
            dbg("→ key down")
            self.onKeyDown?()
        } else if !isDown && self.isKeyDown {
            let held = self.keyDownTime.map { Date().timeIntervalSince($0) * 1000 } ?? 999
            self.isKeyDown = false
            self.keyDownTime = nil
            if held >= self.minHoldMs {
                dbg("→ key up after \(Int(held))ms")
                self.onKeyUp?()
            } else {
                dbg("→ key up ignored (\(Int(held))ms < \(Int(self.minHoldMs))ms)")
            }
        }
    }

    deinit { stop() }
}

private let globalHotKeyCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // macOS silently disables event taps that time out or are blocked. Re-enable immediately
    // so the hotkey keeps working after a long recording session or auto-stop.
    // Raw values: kCGEventTapDisabledByTimeout = 0xFFFFFFFE, kCGEventTapDisabledByUserInput = 0xFFFFFFFF
    let tapDisabledByTimeout   = CGEventType(rawValue: 0xFFFFFFFE)!
    let tapDisabledByUserInput = CGEventType(rawValue: 0xFFFFFFFF)!
    if type == tapDisabledByTimeout || type == tapDisabledByUserInput {
        dbg("eventTap disabled by system (type=\(type.rawValue)) — re-enabling")
        if let tap = monitor.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return nil
    }

    guard type == .flagsChanged else { return Unmanaged.passRetained(event) }

    let kc    = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    switch monitor.option {

    case .rightOption:
        guard kc == 61 else { break }
        let down = flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskShift)
        monitor.fireKeyEvent(isDown: down)

    case .leftOption:
        guard kc == 58 else { break }
        let down = flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskShift)
        monitor.fireKeyEvent(isDown: down)

    case .fn:
        guard kc == 63 else { break }
        let down = flags.contains(.maskSecondaryFn)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl) && !flags.contains(.maskShift)
        monitor.fireKeyEvent(isDown: down)

    case .rightCommand:
        guard kc == 54 else { break }
        let down = flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskControl) && !flags.contains(.maskShift)
        monitor.fireKeyEvent(isDown: down)

    case .ctrlOption:
        // Fire when both Ctrl and Option are held together (either pressed second triggers down).
        let bothDown = flags.contains(.maskControl) && flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand) && !flags.contains(.maskShift)
        if bothDown {
            monitor.fireKeyEvent(isDown: true)
        } else if monitor.isKeyDown {
            // Either modifier released → key up
            monitor.fireKeyEvent(isDown: false)
        }
    }

    return Unmanaged.passRetained(event)
}
