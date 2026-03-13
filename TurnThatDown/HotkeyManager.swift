import AppKit
import Carbon
import CoreGraphics
import Foundation

final class HotkeyManager {
    private weak var tapManager: ProcessTapManager?
    private weak var audioManager: AudioManager?
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?

    init(tapManager: ProcessTapManager, audioManager: AudioManager) {
        self.tapManager = tapManager
        self.audioManager = audioManager
        setupEventTap()
        setupLocalMonitor()
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - CGEvent Tap (global hotkeys)

    private func setupEventTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Use Unmanaged to pass self as refcon
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: refcon
        ) else {
            NSLog("[TurnThatDown] Failed to create CGEvent tap — check Accessibility permissions")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[TurnThatDown] CGEvent tap registered for global hotkeys")
    }

    /// Retry tap creation (called when user grants Accessibility after launch)
    func retryEventTap() {
        guard eventTap == nil else { return }
        setupEventTap()
    }

    var isEventTapActive: Bool {
        eventTap != nil
    }

    // MARK: - Local monitor (when popover is focused)

    private func setupLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil
            }
            return event
        }
    }

    // MARK: - Key handling

    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let hasOption = flags.contains(.option)
        let hasShift = flags.contains(.shift)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)

        // Option+Shift (per-app volume)
        if hasOption && hasShift && !hasControl && !hasCommand {
            switch event.keyCode {
            case UInt16(kVK_UpArrow):
                adjustAppVolume(delta: 0.05)
                return true
            case UInt16(kVK_DownArrow):
                adjustAppVolume(delta: -0.05)
                return true
            case UInt16(kVK_ANSI_M):
                toggleAppMute()
                return true
            default:
                break
            }
        }

        // Control+Option (system volume)
        if hasControl && hasOption && !hasCommand && !hasShift {
            switch event.keyCode {
            case UInt16(kVK_UpArrow):
                adjustSystemVolume(delta: 0.05)
                return true
            case UInt16(kVK_DownArrow):
                adjustSystemVolume(delta: -0.05)
                return true
            case UInt16(kVK_ANSI_M):
                toggleSystemMute()
                return true
            default:
                break
            }
        }

        return false
    }

    /// Handle from CGEvent callback (runs on whatever thread the tap fires on)
    func handleCGEvent(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let hasOption = flags.contains(.maskAlternate)
        let hasShift = flags.contains(.maskShift)
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)

        // Option+Shift (per-app volume)
        if hasOption && hasShift && !hasControl && !hasCommand {
            switch keyCode {
            case UInt16(kVK_UpArrow):
                DispatchQueue.main.async { self.adjustAppVolume(delta: 0.05) }
                return true
            case UInt16(kVK_DownArrow):
                DispatchQueue.main.async { self.adjustAppVolume(delta: -0.05) }
                return true
            case UInt16(kVK_ANSI_M):
                DispatchQueue.main.async { self.toggleAppMute() }
                return true
            default:
                break
            }
        }

        // Control+Option (system volume)
        if hasControl && hasOption && !hasCommand && !hasShift {
            switch keyCode {
            case UInt16(kVK_UpArrow):
                DispatchQueue.main.async { self.adjustSystemVolume(delta: 0.05) }
                return true
            case UInt16(kVK_DownArrow):
                DispatchQueue.main.async { self.adjustSystemVolume(delta: -0.05) }
                return true
            case UInt16(kVK_ANSI_M):
                DispatchQueue.main.async { self.toggleSystemMute() }
                return true
            default:
                break
            }
        }

        return false
    }

    // MARK: - Actions

    private func adjustAppVolume(delta: Float) {
        guard let tapManager, let firstApp = tapManager.tappedApps.first else { return }
        let newVolume = max(0.0, min(2.0, firstApp.volume + delta))
        tapManager.setVolume(newVolume, for: firstApp.id)
    }

    private func toggleAppMute() {
        guard let tapManager, let firstApp = tapManager.tappedApps.first else { return }
        tapManager.toggleMute(for: firstApp.id)
    }

    private func adjustSystemVolume(delta: Float) {
        guard let audioManager else { return }
        let newVolume = max(0.0, min(1.0, audioManager.outputVolume + delta))
        audioManager.setOutputVolume(newVolume)
    }

    private func toggleSystemMute() {
        audioManager?.toggleOutputMute()
    }
}

// C callback for CGEvent tap
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap disabled/timeout — re-enable
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown, let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    if manager.handleCGEvent(keyCode: keyCode, flags: flags) {
        return nil // consume the event
    }

    return Unmanaged.passUnretained(event)
}

