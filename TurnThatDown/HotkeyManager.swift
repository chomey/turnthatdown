import AppKit
import Carbon
import Foundation

final class HotkeyManager {
    private weak var tapManager: ProcessTapManager?
    private weak var audioManager: AudioManager?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(tapManager: ProcessTapManager, audioManager: AudioManager) {
        self.tapManager = tapManager
        self.audioManager = audioManager
        setupMonitors()
    }

    deinit {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func setupMonitors() {
        // Global monitor — catches events when app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Local monitor — catches events when app IS focused (popover open)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil // consume the event
            }
            return event
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Option+Shift shortcuts (per-app)
        if flags == [.option, .shift] {
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

        // Control+Option shortcuts (system)
        if flags == [.control, .option] {
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

    private func adjustAppVolume(delta: Float) {
        guard let tapManager, let firstApp = tapManager.tappedApps.first else { return }
        let newVolume = max(0.0, min(2.0, firstApp.volume + delta))
        DispatchQueue.main.async {
            tapManager.setVolume(newVolume, for: firstApp.id)
        }
    }

    private func toggleAppMute() {
        guard let tapManager, let firstApp = tapManager.tappedApps.first else { return }
        DispatchQueue.main.async {
            tapManager.toggleMute(for: firstApp.id)
        }
    }

    private func adjustSystemVolume(delta: Float) {
        guard let audioManager else { return }
        let newVolume = max(0.0, min(1.0, audioManager.outputVolume + delta))
        DispatchQueue.main.async {
            audioManager.setOutputVolume(newVolume)
        }
    }

    private func toggleSystemMute() {
        guard let audioManager else { return }
        DispatchQueue.main.async {
            audioManager.toggleOutputMute()
        }
    }
}
