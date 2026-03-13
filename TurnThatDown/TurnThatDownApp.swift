import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
struct TurnThatDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let audioManager = AudioManager()
    private let tapManager = ProcessTapManager()
    private var eventMonitor: Any?
    private var scrollMonitor: Any?
    private var hotkeyManager: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "speaker.wave.2.fill",
                accessibilityDescription: "TurnThatDown"
            )
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(audioManager: audioManager, tapManager: tapManager)
        )

        // Check Accessibility permission for global hotkeys
        checkAccessibilityPermission()

        // Initialize global hotkeys
        hotkeyManager = HotkeyManager(tapManager: tapManager, audioManager: audioManager)

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }

        // Scroll wheel on menu bar icon adjusts system volume
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem.button else { return event }
            let buttonWindow = button.window
            if event.window === buttonWindow {
                let delta = Float(event.scrollingDeltaY) * 0.01
                if delta != 0 {
                    let newVolume = self.audioManager.outputVolume + delta
                    self.audioManager.setOutputVolume(newVolume)
                }
                return nil // consume the event
            }
            return event
        }

        // Update menu bar icon when mute state changes
        audioManager.$outputMuted
            .receive(on: RunLoop.main)
            .sink { [weak self] muted in
                self?.updateStatusIcon(muted: muted)
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(muted: Bool) {
        guard let button = statusItem.button else { return }
        let iconName = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        button.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "TurnThatDown"
        )
    }

    @objc private func handleClick(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)

        menu.addItem(NSMenuItem.separator())

        let soundSettings = NSMenuItem(
            title: "Sound Settings...",
            action: #selector(openSoundSettings),
            keyEquivalent: ""
        )
        soundSettings.target = self
        menu.addItem(soundSettings)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit TurnThatDown",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // reset so left-click still opens popover
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // silently ignore — user may not have permission
        }
    }

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            // Show explanation and open settings
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "TurnThatDown needs Accessibility access for global keyboard shortcuts to work when other apps are focused.\n\nGo to System Settings → Privacy & Security → Accessibility and enable TurnThatDown."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }

                // Poll for permission grant so we can activate hotkeys immediately
                self?.pollForAccessibility()
            }
        }
    }

    private var accessibilityTimer: Timer?

    private func pollForAccessibility() {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityTimer = nil
                self?.hotkeyManager?.retryEventTap()
            }
        }
    }

    @objc private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
