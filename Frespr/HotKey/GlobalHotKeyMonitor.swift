import AppKit
import ApplicationServices

final class GlobalHotKeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onPermissionNeeded: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var keyDownTime: Date?
    private var isKeyDown = false

    // Minimum ms the key must be held before a release registers.
    // Prevents the OS's own flagsChanged follow-up event from being
    // treated as a key-up immediately after key-down.
    private let minHoldMs: Double = 150

    func start() {
        dbg("start()")
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
            let trusted = AXIsProcessTrusted()
            dbg("retry tick AX=\(trusted)")
            if trusted {
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

    fileprivate func handleCGEvent(_ event: CGEvent) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        dbg("flagsChanged keyCode=\(kc) flags=\(String(format:"0x%x", flags.rawValue))")

        // keyCode 61 = Right Option only (58 = Left Option, excluded)
        guard kc == 61 else { return }

        // Option is down when maskAlternate is set with no other modifiers
        let optionDown = flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskShift)

        dbg("Option kc=\(kc) down=\(optionDown) isKeyDown=\(isKeyDown)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if optionDown && !self.isKeyDown {
                // Key pressed
                self.isKeyDown = true
                self.keyDownTime = Date()
                dbg("→ key down, firing onKeyDown")
                self.onKeyDown?()

            } else if !optionDown && self.isKeyDown {
                // Key released — always reset state, only fire onKeyUp if held long enough
                let held = self.keyDownTime.map { Date().timeIntervalSince($0) * 1000 } ?? 999
                self.isKeyDown = false
                self.keyDownTime = nil
                if held >= self.minHoldMs {
                    dbg("→ key up after \(Int(held))ms, firing onKeyUp")
                    self.onKeyUp?()
                } else {
                    dbg("→ key up ignored (held only \(Int(held))ms < \(Int(self.minHoldMs))ms)")
                }
            }
        }
    }

    deinit { stop() }
}

private let globalHotKeyCallback: CGEventTapCallBack = { _, _, event, userInfo in
    guard let userInfo else { return Unmanaged.passRetained(event) }
    Unmanaged<GlobalHotKeyMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
        .handleCGEvent(event)
    return Unmanaged.passRetained(event)
}
