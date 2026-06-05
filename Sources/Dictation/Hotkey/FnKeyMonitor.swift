import AppKit
import CoreGraphics

/// Global monitor for the bare `fn` (globe) key.
///
/// The fn key is a hardware modifier — it never produces an ordinary
/// keyDown/keyUp. Instead it shows up as a `.flagsChanged` event carrying the
/// `.maskSecondaryFn` flag. We install a session-level `CGEventTap`, detect the
/// off→on edge, and fire `onToggle`. Requires Accessibility permission;
/// `tapCreate` returns nil until it is granted.
final class FnKeyMonitor {

    /// Called once per fn *press* (the key-down edge). Invoked on the main queue.
    var onToggle: (() -> Void)?

    /// Swallow the fn event so the OS doesn't also act on it (emoji picker etc.).
    var suppressDefault: Bool = true

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDown = false

    /// Returns false if the tap could not be created (usually missing
    /// Accessibility permission) so the caller can retry later.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or on certain input;
        // just re-enable and pass the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let fnNow = flags.contains(.maskSecondaryFn)

        // Only consume the event when fn is the *only* modifier involved, so we
        // never break combos like Shift+fn that other apps may rely on.
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate,
                                       .maskCommand, .maskSecondaryFn, .maskAlphaShift]
        let fnIsolated = flags.intersection(modifiers).subtracting(.maskSecondaryFn).isEmpty

        guard fnNow != fnDown else { return Unmanaged.passUnretained(event) }
        fnDown = fnNow

        if fnNow {
            // Defer the work so the tap callback returns immediately.
            DispatchQueue.main.async { [weak self] in self?.onToggle?() }
        }

        if suppressDefault && fnIsolated {
            return nil // consume both edges symmetrically; downstream never sees fn
        }
        return Unmanaged.passUnretained(event)
    }
}
