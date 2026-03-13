import AudioToolbox
import Combine
import CoreAudio
import Foundation

final class AudioManager: ObservableObject {
    @Published var outputVolume: Float = 0.5
    @Published var inputVolume: Float = 0.5
    @Published var outputMuted: Bool = false
    @Published var inputMuted: Bool = false
    @Published var outputDevices: [AudioDevice] = []
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedOutputDeviceID: AudioDeviceID = 0
    @Published var selectedInputDeviceID: AudioDeviceID = 0
    @Published var outputSampleRate: Double = 0
    @Published var outputBalance: Float = 0.5 // 0.0 = full left, 0.5 = center, 1.0 = full right

    private var cancellables = Set<AnyCancellable>()
    private var listenerBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
        setupSystemListeners()
        setupVolumeBindings()
    }

    deinit {
        removeAllListeners()
    }

    // MARK: - Public

    func refresh() {
        outputDevices = fetchDevices(scope: kAudioObjectPropertyScopeOutput)
        inputDevices = fetchDevices(scope: kAudioObjectPropertyScopeInput)
        selectedOutputDeviceID = getDefaultDevice(scope: kAudioObjectPropertyScopeOutput)
        selectedInputDeviceID = getDefaultDevice(scope: kAudioObjectPropertyScopeInput)
        readOutputVolume()
        readInputVolume()
        readOutputMute()
        readInputMute()
        readOutputSampleRate()
        readOutputBalance()
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID) {
        setDefaultDevice(deviceID, scope: kAudioObjectPropertyScopeOutput)
        selectedOutputDeviceID = deviceID
        readOutputVolume()
        readOutputMute()
        readOutputSampleRate()
        readOutputBalance()
        setupDeviceVolumeListeners()
    }

    func selectInputDevice(_ deviceID: AudioDeviceID) {
        setDefaultDevice(deviceID, scope: kAudioObjectPropertyScopeInput)
        selectedInputDeviceID = deviceID
        readInputVolume()
        readInputMute()
        setupDeviceVolumeListeners()
    }

    func setOutputVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        setVolume(clamped, device: selectedOutputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        outputVolume = clamped
    }

    func setInputVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        setVolume(clamped, device: selectedInputDeviceID, scope: kAudioObjectPropertyScopeInput)
        inputVolume = clamped
    }

    func toggleOutputMute() {
        let newValue = !outputMuted
        setMute(newValue, device: selectedOutputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        outputMuted = newValue
    }

    func toggleInputMute() {
        let newValue = !inputMuted
        setMute(newValue, device: selectedInputDeviceID, scope: kAudioObjectPropertyScopeInput)
        inputMuted = newValue
    }

    // MARK: - Device Enumeration

    private func fetchDevices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id -> AudioDevice? in
            guard let name = getDeviceName(id),
                  let uid = getDeviceUID(id) else { return nil }
            let hasOutput = deviceHasChannels(id, scope: kAudioObjectPropertyScopeOutput)
            let hasInput = deviceHasChannels(id, scope: kAudioObjectPropertyScopeInput)

            let matchesScope = (scope == kAudioObjectPropertyScopeOutput) ? hasOutput : hasInput
            guard matchesScope else { return nil }

            // Filter out TurnThatDown aggregate devices
            if name.hasPrefix("TurnThatDown-") { return nil }

            let transport = getTransportType(id)

            return AudioDevice(
                id: id,
                name: name,
                uid: uid,
                hasOutput: hasOutput,
                hasInput: hasInput,
                transportType: transport
            )
        }
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }
        return name as String
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else {
            return nil
        }
        return uid as String
    }

    private func deviceHasChannels(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func getTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return transport
    }

    // MARK: - Default Device

    private func getDefaultDevice(scope: AudioObjectPropertyScope) -> AudioDeviceID {
        let selector: AudioObjectPropertySelector = (scope == kAudioObjectPropertyScopeOutput)
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultInputDevice

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private func setDefaultDevice(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) {
        let selector: AudioObjectPropertySelector = (scope == kAudioObjectPropertyScopeOutput)
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultInputDevice

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id
        )
    }

    // MARK: - Volume

    private func readOutputVolume() {
        outputVolume = getVolume(device: selectedOutputDeviceID, scope: kAudioObjectPropertyScopeOutput)
    }

    private func readInputVolume() {
        inputVolume = getVolume(device: selectedInputDeviceID, scope: kAudioObjectPropertyScopeInput)
    }

    private func readOutputMute() {
        outputMuted = getMute(device: selectedOutputDeviceID, scope: kAudioObjectPropertyScopeOutput)
    }

    private func readInputMute() {
        inputMuted = getMute(device: selectedInputDeviceID, scope: kAudioObjectPropertyScopeInput)
    }

    func setOutputBalance(_ value: Float) {
        let clamped = max(0, min(1, value))
        // Balance is set by adjusting per-channel volume: channel 1 = left, channel 2 = right
        let leftVolume = outputVolume * min(1.0, 2.0 * (1.0 - clamped))
        let rightVolume = outputVolume * min(1.0, 2.0 * clamped)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 1
        )
        if AudioObjectHasProperty(selectedOutputDeviceID, &address) {
            var vol = leftVolume
            let size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectSetPropertyData(selectedOutputDeviceID, &address, 0, nil, size, &vol)
        }
        address.mElement = 2
        if AudioObjectHasProperty(selectedOutputDeviceID, &address) {
            var vol = rightVolume
            let size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectSetPropertyData(selectedOutputDeviceID, &address, 0, nil, size, &vol)
        }
        outputBalance = clamped
    }

    private func readOutputBalance() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 1
        )
        var leftVol: Float32 = 0
        var rightVol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        if AudioObjectHasProperty(selectedOutputDeviceID, &address) {
            AudioObjectGetPropertyData(selectedOutputDeviceID, &address, 0, nil, &size, &leftVol)
        }
        address.mElement = 2
        if AudioObjectHasProperty(selectedOutputDeviceID, &address) {
            AudioObjectGetPropertyData(selectedOutputDeviceID, &address, 0, nil, &size, &rightVol)
        }

        let total = leftVol + rightVol
        if total > 0 {
            outputBalance = rightVol / total
        } else {
            outputBalance = 0.5
        }
    }

    private func readOutputSampleRate() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(selectedOutputDeviceID, &address, 0, nil, &size, &sampleRate) == noErr {
            outputSampleRate = sampleRate
        }
    }

    private func getVolume(device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float {
        // Try virtual main volume first
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(device, &address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        // Fallback to main volume
        address.mSelector = kAudioDevicePropertyVolumeScalar
        address.mElement = kAudioObjectPropertyElementMain
        if AudioObjectHasProperty(device, &address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        // Try channel 1
        address.mElement = 1
        if AudioObjectHasProperty(device, &address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        return 0.5
    }

    private func setVolume(_ volume: Float, device: AudioDeviceID, scope: AudioObjectPropertyScope) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(device, &address) {
            var vol = volume
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol) == noErr {
                return
            }
        }

        // Fallback: set per-channel
        address.mSelector = kAudioDevicePropertyVolumeScalar
        for channel: UInt32 in [1, 2] {
            address.mElement = channel
            if AudioObjectHasProperty(device, &address) {
                var vol = volume
                let size = UInt32(MemoryLayout<Float32>.size)
                AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol)
            }
        }
    }

    private func getMute(device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(device, &address) {
            return false
        }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
            return false
        }
        return muted != 0
    }

    private func setMute(_ muted: Bool, device: AudioDeviceID, scope: AudioObjectPropertyScope) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(device, &address) else { return }

        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    // MARK: - Listeners

    private func setupSystemListeners() {
        // Listen for device list changes
        addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        ) { [weak self] in
            self?.refresh()
        }

        // Listen for default output device changes
        addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            guard let self else { return }
            self.selectedOutputDeviceID = self.getDefaultDevice(scope: kAudioObjectPropertyScopeOutput)
            self.readOutputVolume()
            self.readOutputMute()
        }

        // Listen for default input device changes
        addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        ) { [weak self] in
            guard let self else { return }
            self.selectedInputDeviceID = self.getDefaultDevice(scope: kAudioObjectPropertyScopeInput)
            self.readInputVolume()
            self.readInputMute()
        }

        setupDeviceVolumeListeners()
    }

    private func setupDeviceVolumeListeners() {
        // Remove old device-specific listeners
        removeDeviceListeners()

        // Output volume changes
        if selectedOutputDeviceID != 0 {
            addDeviceListener(
                objectID: selectedOutputDeviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioObjectPropertyScopeOutput
            ) { [weak self] in
                self?.readOutputVolume()
            }

            addDeviceListener(
                objectID: selectedOutputDeviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeOutput
            ) { [weak self] in
                self?.readOutputMute()
            }
        }

        // Input volume changes
        if selectedInputDeviceID != 0 {
            addDeviceListener(
                objectID: selectedInputDeviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioObjectPropertyScopeInput
            ) { [weak self] in
                self?.readInputVolume()
            }

            addDeviceListener(
                objectID: selectedInputDeviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeInput
            ) { [weak self] in
                self?.readInputMute()
            }
        }
    }

    private func addListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping () -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { handler() }
        }

        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
        if status == noErr {
            listenerBlocks.append((objectID, address, block))
        }
    }

    private func addDeviceListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        handler: @escaping () -> Void
    ) {
        addListener(objectID: objectID, selector: selector, scope: scope, handler: handler)
    }

    private func removeDeviceListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        listenerBlocks = listenerBlocks.filter { objectID, address, block in
            if objectID != systemObject {
                var addr = address
                AudioObjectRemovePropertyListenerBlock(objectID, &addr, DispatchQueue.main, block)
                return false
            }
            return true
        }
    }

    private func removeAllListeners() {
        for (objectID, address, block) in listenerBlocks {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(objectID, &addr, DispatchQueue.main, block)
        }
        listenerBlocks.removeAll()
    }

    // MARK: - Volume Bindings (for slider two-way binding)

    private var isUpdatingFromSlider = false

    private func setupVolumeBindings() {
        $outputVolume
            .removeDuplicates()
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] value in
                guard let self, !self.isUpdatingFromSlider else { return }
                // Volume updated externally, no action needed
            }
            .store(in: &cancellables)
    }

    func sliderOutputVolumeChanged(_ value: Float) {
        isUpdatingFromSlider = true
        setOutputVolume(value)
        isUpdatingFromSlider = false
    }

    func sliderInputVolumeChanged(_ value: Float) {
        isUpdatingFromSlider = true
        setInputVolume(value)
        isUpdatingFromSlider = false
    }
}
