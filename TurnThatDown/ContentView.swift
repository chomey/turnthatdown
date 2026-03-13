import CoreAudio
import SwiftUI

struct ContentView: View {
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var tapManager: ProcessTapManager

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HeaderView()

                Divider().padding(.horizontal)

                OutputSection(audioManager: audioManager)

                Divider().padding(.horizontal)

                InputSection(audioManager: audioManager)

                Divider().padding(.horizontal)

                AppVolumeSection(tapManager: tapManager, audioManager: audioManager)

                Divider().padding(.horizontal)

                FooterView()
            }
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .frame(minHeight: 300, maxHeight: 600)
    }
}

// MARK: - Header

struct HeaderView: View {
    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("TurnThatDown")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Output Section

struct OutputSection: View {
    @ObservedObject var audioManager: AudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Output", icon: "speaker.wave.2")

            // Device picker
            DevicePicker(
                devices: audioManager.outputDevices,
                selectedDeviceID: audioManager.selectedOutputDeviceID,
                onSelect: { audioManager.selectOutputDevice($0) }
            )

            // Volume slider
            VolumeSliderRow(
                volume: Binding(
                    get: { audioManager.outputVolume },
                    set: { audioManager.sliderOutputVolumeChanged($0) }
                ),
                isMuted: audioManager.outputMuted,
                onToggleMute: { audioManager.toggleOutputMute() },
                lowIcon: "speaker.fill",
                highIcon: "speaker.wave.3.fill"
            )

            // System balance
            BalanceSliderRow(
                balance: Binding(
                    get: { (audioManager.outputBalance - 0.5) * 2 }, // convert 0..1 to -1..1
                    set: { audioManager.setOutputBalance(($0 + 1) / 2) } // convert -1..1 to 0..1
                )
            )

            // Sample rate
            if audioManager.outputSampleRate > 0 {
                HStack {
                    Spacer()
                    Text(formatSampleRate(audioManager.outputSampleRate))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func formatSampleRate(_ rate: Double) -> String {
        if rate >= 1000 {
            let khz = rate / 1000
            if khz == khz.rounded() {
                return "\(Int(khz)) kHz"
            }
            return String(format: "%.1f kHz", khz)
        }
        return "\(Int(rate)) Hz"
    }
}

// MARK: - Input Section

struct InputSection: View {
    @ObservedObject var audioManager: AudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Input", icon: "mic")

            DevicePicker(
                devices: audioManager.inputDevices,
                selectedDeviceID: audioManager.selectedInputDeviceID,
                onSelect: { audioManager.selectInputDevice($0) }
            )

            VolumeSliderRow(
                volume: Binding(
                    get: { audioManager.inputVolume },
                    set: { audioManager.sliderInputVolumeChanged($0) }
                ),
                isMuted: audioManager.inputMuted,
                onToggleMute: { audioManager.toggleInputMute() },
                lowIcon: "mic.slash.fill",
                highIcon: "mic.fill"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - App Volume Section

struct AppVolumeSection: View {
    @ObservedObject var tapManager: ProcessTapManager
    @ObservedObject var audioManager: AudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Applications", icon: "square.stack")
                Spacer()
                if !tapManager.hiddenBundleIDs.isEmpty {
                    Menu {
                        ForEach(Array(tapManager.hiddenBundleIDs).sorted(), id: \.self) { bundleID in
                            Button("Show \(bundleID)") {
                                tapManager.unhideApp(bundleID)
                            }
                        }
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Hidden apps")
                }
            }

            if tapManager.tappedApps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No apps playing audio")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                ForEach(tapManager.tappedApps) { app in
                    AppVolumeRow(app: app, tapManager: tapManager, outputDevices: audioManager.outputDevices)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct AppVolumeRow: View {
    let app: TappedApp
    @ObservedObject var tapManager: ProcessTapManager
    let outputDevices: [AudioDevice]
    @State private var showBalance = false
    @State private var showEQ = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                Text(app.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()

                // EQ toggle
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showEQ.toggle() } }) {
                    Image(systemName: "slider.vertical.3")
                        .font(.caption)
                        .foregroundStyle(app.eqEnabled ? .blue : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Equalizer")

                // Balance toggle
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showBalance.toggle() } }) {
                    Image(systemName: "slider.horizontal.2.square")
                        .font(.caption)
                        .foregroundStyle(app.balance != 0 ? .blue : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Balance (L/R panning)")

                // Output device routing picker
                Menu {
                    Button(action: {
                        tapManager.setOutputDevice(nil, for: app.id)
                    }) {
                        HStack {
                            Text("Default Output")
                            if app.outputDeviceUID == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(outputDevices.filter { !$0.name.hasPrefix("TurnThatDown-") }) { device in
                        Button(action: {
                            tapManager.setOutputDevice(device.uid, for: app.id)
                        }) {
                            HStack {
                                Image(systemName: device.iconName)
                                Text(device.name)
                                if app.outputDeviceUID == device.uid {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: app.outputDeviceUID != nil ? "speaker.badge.exclamationmark" : "speaker.wave.1")
                        .font(.caption)
                        .foregroundStyle(app.outputDeviceUID != nil ? .blue : .secondary)
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(app.outputDeviceUID != nil ? "Routed to custom device" : "Output device (default)")
            }

            VolumeSliderRow(
                volume: Binding(
                    get: { app.volume },
                    set: { tapManager.setVolume($0, for: app.id) }
                ),
                isMuted: app.isMuted,
                onToggleMute: { tapManager.toggleMute(for: app.id) },
                lowIcon: "speaker.slash.fill",
                highIcon: "speaker.wave.2.fill",
                maxVolume: 2.0
            )

            if showBalance {
                BalanceSliderRow(
                    balance: Binding(
                        get: { app.balance },
                        set: { tapManager.setBalance($0, for: app.id) }
                    )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showEQ {
                AppEQView(app: app, tapManager: tapManager)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // VU meter - thin bar showing current audio level
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(app.audioLevel > 0.8 ? Color.red : Color.green.opacity(0.7))
                    .frame(width: max(0, geometry.size.width * CGFloat(app.audioLevel)), height: 3)
            }
            .frame(height: 3)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Hide \"\(app.name)\"") {
                tapManager.hideApp(app.id)
            }
        }
    }
}

struct BalanceSliderRow: View {
    @Binding var balance: Float

    private var label: String {
        if balance < -0.01 { return "L\(Int(abs(balance) * 100))" }
        if balance > 0.01 { return "R\(Int(balance * 100))" }
        return "C"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("L")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(height: 4)

                    // Center marker
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: 8)
                        .offset(x: geometry.size.width / 2)

                    // Balance indicator
                    let center = geometry.size.width / 2
                    let offset = center * CGFloat(balance)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: abs(offset), height: 4)
                        .offset(x: balance >= 0 ? center : center + offset)
                }
                .frame(height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = Float(value.location.x / geometry.size.width)
                            balance = max(-1, min(1, (fraction - 0.5) * 2))
                        }
                )
                .onTapGesture(count: 2) {
                    balance = 0 // double-tap to center
                }
            }
            .frame(height: 14)

            Text("R")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - EQ View

struct AppEQView: View {
    let app: TappedApp
    @ObservedObject var tapManager: ProcessTapManager

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button(action: { tapManager.toggleEQ(for: app.id) }) {
                    Text("EQ")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(app.eqEnabled ? .blue : .secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Reset") {
                    tapManager.resetEQ(for: app.id)
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(Array(app.eqBands.enumerated()), id: \.offset) { index, band in
                    EQBandSlider(
                        gain: Binding(
                            get: { band.gain },
                            set: { tapManager.setEQGain($0, band: index, for: app.id) }
                        ),
                        label: band.label
                    )
                }
            }
            .frame(height: 80)
            .opacity(app.eqEnabled ? 1.0 : 0.4)
        }
        .padding(.vertical, 4)
    }
}

struct EQBandSlider: View {
    @Binding var gain: Float // -12 to +12 dB
    let label: String

    private var fraction: CGFloat {
        CGFloat((gain + 12) / 24) // normalize to 0..1
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(gain >= 0 ? "+\(Int(gain))" : "\(Int(gain))")
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(height: 12)

            GeometryReader { geometry in
                ZStack {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(width: 4)

                    // Center line (0 dB)
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 8, height: 1)
                        .offset(y: 0)

                    // Fill from center
                    let center = geometry.size.height / 2
                    let pos = geometry.size.height * (1 - fraction)
                    let fillHeight = abs(pos - center)
                    let fillOffset = gain >= 0 ? -(fillHeight / 2) : (fillHeight / 2)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(abs(gain) > 9 ? Color.orange : Color.accentColor)
                        .frame(width: 4, height: fillHeight)
                        .offset(y: fillOffset)

                    // Thumb
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .offset(y: pos - center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = 1 - Float(value.location.y / geometry.size.height)
                            gain = max(-12, min(12, fraction * 24 - 12))
                        }
                )
                .onTapGesture(count: 2) {
                    gain = 0
                }
            }

            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(height: 12)
        }
    }
}

// MARK: - Shared Components

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct DevicePicker: View {
    let devices: [AudioDevice]
    let selectedDeviceID: AudioDeviceID
    let onSelect: (AudioDeviceID) -> Void

    var body: some View {
        Menu {
            ForEach(devices) { device in
                Button(action: { onSelect(device.id) }) {
                    HStack {
                        Image(systemName: device.iconName)
                        Text(device.name)
                        if device.id == selectedDeviceID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack {
                let selected = devices.first(where: { $0.id == selectedDeviceID })
                Image(systemName: selected?.iconName ?? "speaker.wave.2")
                    .frame(width: 16)
                Text(selected?.name ?? "No Device")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct VolumeSliderRow: View {
    @Binding var volume: Float
    let isMuted: Bool
    let onToggleMute: () -> Void
    let lowIcon: String
    let highIcon: String
    var maxVolume: Float = 1.0

    @State private var isEditing = false
    @State private var editText = ""

    private var sliderFraction: CGFloat {
        CGFloat(volume / maxVolume)
    }

    private var fillColor: Color {
        if isMuted { return Color.red.opacity(0.5) }
        if volume > 1.0 { return Color.orange }
        return Color.accentColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleMute) {
                Image(systemName: isMuted ? lowIcon : (volume == 0 ? lowIcon : "speaker.fill"))
                    .font(.callout)
                    .foregroundStyle(isMuted ? .red : .primary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(height: 6)

                    // Filled portion
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillColor)
                        .frame(width: max(0, geometry.size.width * sliderFraction), height: 6)
                }
                .frame(height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let newVolume = Float(value.location.x / geometry.size.width) * maxVolume
                            volume = max(0, min(maxVolume, newVolume))
                        }
                )
            }
            .frame(height: 20)

            if isEditing {
                TextField("", text: $editText, onCommit: {
                    commitVolumeEdit()
                })
                .font(.caption.monospacedDigit())
                .frame(width: 40)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .onExitCommand { isEditing = false }
                .onAppear {
                    // Select all text when editing starts
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                }
            } else {
                Text("\(Int(volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editText = "\(Int(volume * 100))"
                        isEditing = true
                    }
            }
        }
    }

    private func commitVolumeEdit() {
        isEditing = false
        let cleaned = editText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let percent = Float(cleaned) {
            let newVolume = max(0, min(maxVolume, percent / 100.0))
            volume = newVolume
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @State private var showShortcuts = false

    var body: some View {
        VStack(spacing: 4) {
            if showShortcuts {
                VStack(alignment: .leading, spacing: 3) {
                    ShortcutRow(keys: "⌥⇧↑/↓", action: "App volume")
                    ShortcutRow(keys: "⌥⇧M", action: "App mute")
                    ShortcutRow(keys: "⌃⌥↑/↓", action: "System volume")
                    ShortcutRow(keys: "⌃⌥M", action: "System mute")
                    ShortcutRow(keys: "Scroll", action: "Menu bar icon → volume")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack {
                Button("Sound Settings...") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showShortcuts.toggle()
                    }
                }) {
                    Image(systemName: "keyboard")
                        .font(.caption)
                        .foregroundStyle(showShortcuts ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Keyboard shortcuts")

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit TurnThatDown")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 80, alignment: .trailing)
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
