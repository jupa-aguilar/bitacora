import AppKit
import CoreGraphics
import Foundation

/// Watches the desktop and turns activity into triggers for the engine.
///
/// Only *timing* of input is observed: keystrokes are never read or stored, they just restart
/// the "typing pause" timer. Must be started on the main thread with the main run loop running.
public final class EventSources {
    private let engine: CaptureEngine
    private let config: BitacoraConfig
    private let accessibility = AccessibilityReader()

    private var eventTap: CFMachPort?
    private var timers: [Timer] = []
    private var typingTimer: Timer?
    private var scrollTimer: Timer?
    private var lastBundleID: String?
    private var lastWindowTitle: String?
    private var lastPasteboardChange = NSPasteboard.general.changeCount

    public private(set) var inputMonitoringActive = false

    public init(engine: CaptureEngine, config: BitacoraConfig) {
        self.engine = engine
        self.config = config
    }

    public func start() {
        inputMonitoringActive = installEventTap()
        if !inputMonitoringActive {
            Log.info("input monitoring unavailable: click/typing/scroll triggers disabled (grant Accessibility to enable)")
        }
        schedule(every: 1.0) { [weak self] in self?.pollFocusAndClipboard() }
        schedule(every: config.visualCheckInterval) { [weak self] in self?.emit(.visualChange) }
        schedule(every: 0.25) { [weak self] in
            guard let engine = self?.engine else { return }
            Task { await engine.tick() }
        }
        emit(.manual) // first frame right away
    }

    public func stop() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        typingTimer?.invalidate()
        scrollTimer?.invalidate()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
    }

    private func emit(_ kind: TriggerKind) {
        let trigger = Trigger(kind)
        Task { await engine.submit(trigger) }
    }

    private func schedule(every interval: TimeInterval, _ block: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    /// App switches, window changes and clipboard changes are polled: simple and permission-free.
    private func pollFocusAndClipboard() {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let title = accessibility.currentContext().windowTitle
        if bundleID != lastBundleID {
            if lastBundleID != nil { emit(.appSwitch) }
        } else if title != lastWindowTitle {
            emit(.windowFocus)
        }
        lastBundleID = bundleID
        lastWindowTitle = title

        let change = NSPasteboard.general.changeCount
        if change != lastPasteboardChange {
            lastPasteboardChange = change
            emit(.clipboard)
        }
    }

    // MARK: - Input (listen-only event tap)

    private func installEventTap() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<EventSources>.fromOpaque(userInfo).takeUnretainedValue().handle(type)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        return true
    }

    private func handle(_ type: CGEventType) {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            emit(.click)
        case .keyDown:
            typingTimer?.invalidate()
            typingTimer = Timer.scheduledTimer(withTimeInterval: config.typingPauseDelay, repeats: false) { [weak self] _ in
                self?.emit(.typingPause)
            }
        case .scrollWheel:
            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: config.scrollStopDelay, repeats: false) { [weak self] _ in
                self?.emit(.scrollStop)
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        default:
            break
        }
    }
}
