import AppKit
import AudioToolbox
import CoreAudio
import Foundation

private func ttdLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: "/tmp/ttd_debug.log") {
            if let fh = FileHandle(forWritingAtPath: "/tmp/ttd_debug.log") {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: "/tmp/ttd_debug.log", contents: data)
        }
    }
}

struct TappedApp: Identifiable {
    let id: String // bundle ID
    let name: String
    let icon: NSImage?
    let pid: pid_t
    let processObjectID: AudioObjectID
    var volume: Float
    var isMuted: Bool
    var audioLevel: Float = 0
    var outputDeviceUID: String? = nil // nil = follow system default
    var balance: Float = 0 // -1.0 (full left) to 1.0 (full right), 0 = center
    var eqBands: [EQBand] = EQProcessor.defaultBands
    var eqEnabled: Bool = false
}

final class ProcessTapManager: ObservableObject {
    @Published var tappedApps: [TappedApp] = []
    @Published var hiddenBundleIDs: Set<String> = []

    private var activeTaps: [String: AppTap] = [:]
    private var refreshTimer: Timer?

    // Stored as a class so we can pass a pointer to the C callback
    private class AppTap {
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioDeviceID
        var ioProcID: AudioDeviceIOProcID?
        let bundleID: String
        var volume: Float = 1.0
        var muted: Bool = false
        var callCount: Int = 0
        var audioLevel: Float = 0
        var outputDeviceUID: String? = nil
        var balance: Float = 0 // -1.0 left, 0 center, 1.0 right
        let eq: EQProcessor = EQProcessor()

        init(tapID: AudioObjectID, aggregateDeviceID: AudioDeviceID, bundleID: String) {
            self.tapID = tapID
            self.aggregateDeviceID = aggregateDeviceID
            self.bundleID = bundleID
        }
    }

    init() {
        ttdLog("[TurnThatDown] ProcessTapManager initialized, starting monitoring...")

        // Load hidden apps
        if let hidden = UserDefaults.standard.stringArray(forKey: "hiddenApps") {
            hiddenBundleIDs = Set(hidden)
        }

        // Clean up stale aggregate devices from previous runs
        cleanupStaleAggregateDevices()

        // Check screen capture authorization (required for process taps to deliver audio data)
        let hasAccess = CGPreflightScreenCaptureAccess()
        ttdLog("[TurnThatDown] Screen capture access: \(hasAccess)")
        if !hasAccess {
            let granted = CGRequestScreenCaptureAccess()
            ttdLog("[TurnThatDown] Screen capture access requested, granted: \(granted)")
        }

        startMonitoring()
    }

    deinit {
        stopMonitoring()
        removeAllTaps()
    }

    // MARK: - Public

    func setVolume(_ volume: Float, for bundleID: String) {
        guard let index = tappedApps.firstIndex(where: { $0.id == bundleID }) else { return }
        tappedApps[index].volume = volume
        activeTaps[bundleID]?.volume = tappedApps[index].isMuted ? 0 : volume
        let app = tappedApps[index]
        saveSettings(for: bundleID, volume: volume, muted: app.isMuted, outputDeviceUID: app.outputDeviceUID, balance: app.balance, eqBands: app.eqBands, eqEnabled: app.eqEnabled)
    }

    func toggleMute(for bundleID: String) {
        guard let index = tappedApps.firstIndex(where: { $0.id == bundleID }) else { return }
        tappedApps[index].isMuted.toggle()
        activeTaps[bundleID]?.muted = tappedApps[index].isMuted
        activeTaps[bundleID]?.volume = tappedApps[index].isMuted ? 0 : tappedApps[index].volume
        let app = tappedApps[index]
        saveSettings(for: bundleID, volume: app.volume, muted: app.isMuted, outputDeviceUID: app.outputDeviceUID, balance: app.balance, eqBands: app.eqBands, eqEnabled: app.eqEnabled)
    }

    func setEQGain(_ gain: Float, band: Int, for bundleID: String) {
        guard let index = tappedApps.firstIndex(where: { $0.id == bundleID }) else { return }
        tappedApps[index].eqBands[band].gain = max(-12, min(12, gain))
        activeTaps[bundleID]?.eq.setGain(gain, forBand: band)
        saveSettings(for: bundleID, volume: tappedApps[index].volume, muted: tappedApps[index].isMuted, outputDeviceUID: tappedApps[index].outputDeviceUID, balance: tappedApps[index].balance, eqBands: tappedApps[index].eqBands, eqEnabled: tappedApps[index].eqEnabled)
    }

    func toggleEQ(for bundleID: String) {
        guard let index = tappedApps.firstIndex(where: { $0.id == bundleID }) else { return }
        tappedApps[index].eqEnabled.toggle()
        activeTaps[bundleID]?.eq.enabled = tappedApps[index].eqEnabled
        saveSettings(for: bundleID, volume: tappedApps[index].volume, muted: tappedApps[index].isMuted, outputDeviceUID: tappedApps[index].outputDeviceUID, balance: tappedApps[index].balance, eqBands: tappedApps[index].eqBands, eqEnabled: tappedApps[index].eqEnabled)
    }

    func resetEQ(for bundleID: String) {
        guard let index = tappedApps.firstIndex(where: { $0.id == bundleID }) else { return }
        tappedApps[index].eqBands = EQProcessor.defaultBands
        activeTaps[bundleID]?.eq.reset()
        saveSettings(for: bundleID, volume: tappedApps[index].volume, muted: tappedApps[index].isMuted, outputDeviceUID: tappedApps[index].outputDeviceUID, balance: tappedApps[index].balance, eqBands: tappedApps[index].eqBands, eqEnabled: tappedApps[index].eqEnabled)
    }

    func hideApp(_ bundleID: String) {
        hiddenBundleIDs.insert(bundleID)
        UserDefaults.standard.set(Array(hiddenBundleIDs), forKey: "hiddenApps")
        removeTap(for: bundleID)
        tappedApps.removeAll { $0.id == bundleID }
    }

    func unhideApp(_ bundleID: String) {
        hiddenBundleIDs.remove(bundleID)
        UserDefaults.standard.set(Array(hiddenBundleIDs), forKey: "hiddenApps")
        // Will be picked up on next refresh cycle
    }

    func setBalance(_ balance: Float, for bundleID: String) {
        let clamped = max(-1, min(1, balance))
        guard let index = tappedApps.firstIndex(where: { $0.id == bundleID }) else { return }
        tappedApps[index].balance = clamped
        activeTaps[bundleID]?.balance = clamped
        saveSettings(for: bundleID, volume: tappedApps[index].volume, muted: tappedApps[index].isMuted, outputDeviceUID: tappedApps[index].outputDeviceUID, balance: clamped, eqBands: tappedApps[index].eqBands, eqEnabled: tappedApps[index].eqEnabled)
    }

    func setOutputDevice(_ deviceUID: String?, for bundleID: String) {
        guard let index = tappedApps.firstIndex(where: { $0.id == bundleID }) else { return }
        tappedApps[index].outputDeviceUID = deviceUID

        // Preserve current settings
        let volume = tappedApps[index].volume
        let muted = tappedApps[index].isMuted
        let balance = tappedApps[index].balance

        // Tear down existing tap
        removeTap(for: bundleID)

        // Recreate the tap with the new output device
        createTap(for: tappedApps[index])

        // Restore settings on the new tap
        activeTaps[bundleID]?.volume = muted ? 0 : volume
        activeTaps[bundleID]?.muted = muted
        activeTaps[bundleID]?.outputDeviceUID = deviceUID
        activeTaps[bundleID]?.balance = balance

        let app = tappedApps[index]
        saveSettings(for: bundleID, volume: volume, muted: muted, outputDeviceUID: deviceUID, balance: balance, eqBands: app.eqBands, eqEnabled: app.eqEnabled)
    }

    func getOutputDeviceUID(for bundleID: String) -> String? {
        return tappedApps.first(where: { $0.id == bundleID })?.outputDeviceUID
    }

    // MARK: - Persistent Settings

    private func saveSettings(for bundleID: String, volume: Float, muted: Bool, outputDeviceUID: String? = nil, balance: Float = 0, eqBands: [EQBand]? = nil, eqEnabled: Bool = false) {
        var allSettings = UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: [String: Any]] ?? [:]
        var entry: [String: Any] = ["volume": volume, "muted": muted, "balance": balance, "eqEnabled": eqEnabled]
        if let uid = outputDeviceUID {
            entry["outputDeviceUID"] = uid
        }
        if let bands = eqBands {
            entry["eqGains"] = bands.map { $0.gain }
        }
        allSettings[bundleID] = entry
        UserDefaults.standard.set(allSettings, forKey: "appVolumes")
    }

    private func loadSettings(for bundleID: String) -> (volume: Float, muted: Bool, outputDeviceUID: String?, balance: Float, eqGains: [Float]?, eqEnabled: Bool)? {
        guard let allSettings = UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: [String: Any]],
              let settings = allSettings[bundleID],
              let volume = settings["volume"] as? Float,
              let muted = settings["muted"] as? Bool else { return nil }
        let outputDeviceUID = settings["outputDeviceUID"] as? String
        let balance = settings["balance"] as? Float ?? 0
        let eqGains = settings["eqGains"] as? [Float]
        let eqEnabled = settings["eqEnabled"] as? Bool ?? false
        return (volume, muted, outputDeviceUID, balance, eqGains, eqEnabled)
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        refreshAudioProcesses()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshAudioProcesses()
        }
    }

    private func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshAudioProcesses() {
        let processes = getAudioProcesses()
        ttdLog("[TurnThatDown] Refresh: found \(processes.count) audio processes: \(processes.map { $0.bundleID })")
        let currentBundleIDs = Set(processes.map { $0.bundleID })
        let existingBundleIDs = Set(tappedApps.map { $0.id })

        // Only remove taps when the process has actually quit (not just stopped outputting)
        // The tap mutes the process output, so isRunningOutput may become false while tapped
        for tappedApp in tappedApps {
            let processStillRunning = kill(tappedApp.pid, 0) == 0
            if !processStillRunning {
                removeTap(for: tappedApp.id)
                tappedApps.removeAll { $0.id == tappedApp.id }
            }
        }

        // Add taps for new audio processes
        for process in processes where !existingBundleIDs.contains(process.bundleID) {
            if process.pid == ProcessInfo.processInfo.processIdentifier { continue }
            let skipBundleIDs: Set<String> = [
                "com.apple.CoreSpeech", "com.apple.mediaremoted",
                "com.apple.audiomxd", "com.apple.replayd",
                "systemsoundserverd", "com.apple.controlcenter",
                "com.turnthatdown.app",
            ]
            if skipBundleIDs.contains(process.bundleID) { continue }
            if hiddenBundleIDs.contains(process.bundleID) { continue }

            let app = NSRunningApplication(processIdentifier: process.pid)
            let name = app?.localizedName ?? process.bundleID
            let icon = app?.icon

            // Restore saved settings if available
            let saved = loadSettings(for: process.bundleID)
            let volume = saved?.volume ?? 1.0
            let muted = saved?.muted ?? false
            let outputDeviceUID = saved?.outputDeviceUID
            let balance = saved?.balance ?? 0
            let eqEnabled = saved?.eqEnabled ?? false

            var eqBands = EQProcessor.defaultBands
            if let gains = saved?.eqGains, gains.count == eqBands.count {
                for i in 0..<eqBands.count {
                    eqBands[i].gain = gains[i]
                }
            }

            let tappedApp = TappedApp(
                id: process.bundleID,
                name: name,
                icon: icon,
                pid: process.pid,
                processObjectID: process.objectID,
                volume: volume,
                isMuted: muted,
                outputDeviceUID: outputDeviceUID,
                balance: balance,
                eqBands: eqBands,
                eqEnabled: eqEnabled
            )
            tappedApps.append(tappedApp)
            createTap(for: tappedApp)
        }

        // Update audio levels from active taps
        for index in tappedApps.indices {
            if let tap = activeTaps[tappedApps[index].id] {
                tappedApps[index].audioLevel = tap.audioLevel
            }
        }

        // Sort by audio level (loudest first), then alphabetically for ties
        tappedApps.sort {
            if abs($0.audioLevel - $1.audioLevel) > 0.01 {
                return $0.audioLevel > $1.audioLevel
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Process Enumeration

    private struct AudioProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
    }

    private func getAudioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs
        ) == noErr else { return [] }

        return objectIDs.compactMap { objectID -> AudioProcess? in
            guard isProcessRunningOutput(objectID) else { return nil }
            guard let pid = getProcessPID(objectID) else { return nil }
            guard let bundleID = getProcessBundleID(objectID), !bundleID.isEmpty else { return nil }
            return AudioProcess(objectID: objectID, pid: pid, bundleID: bundleID)
        }
    }

    private func isProcessRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning) == noErr else {
            return false
        }
        return isRunning != 0
    }

    private func getProcessPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    private func getProcessBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &bundleID) == noErr else {
            return nil
        }
        return bundleID as String
    }

    // MARK: - Tap Creation

    private func getDefaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

    private func createTap(for app: TappedApp) {
        // Use the app's custom output device UID, or fall back to system default
        let outputUID: String
        if let customUID = app.outputDeviceUID {
            outputUID = customUID
        } else {
            guard let defaultUID = getDefaultOutputDeviceUID() else {
                ttdLog("[TurnThatDown] Failed to get output device UID")
                return
            }
            outputUID = defaultUID
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [app.processObjectID])
        tapDescription.uuid = UUID()
        tapDescription.name = "TurnThatDown-\(app.id)"
        tapDescription.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        let tapUIDString = tapDescription.uuid.uuidString

        var tapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else {
            ttdLog("[TurnThatDown] Failed to create tap for \(app.name): \(tapStatus)")
            return
        }
        ttdLog("[TurnThatDown] Created tap for \(app.name), tapID=\(tapID)")

        // Aggregate device with output sub-device + tap
        let aggregateUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "TurnThatDown-\(app.id)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceClockDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: outputUID,
                    kAudioSubDeviceDriftCompensationKey as String: false,
                ],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUIDString,
                ],
            ],
        ]

        var aggregateID: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard aggStatus == noErr else {
            ttdLog("[TurnThatDown] Failed to create aggregate for \(app.name): \(aggStatus)")
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        // Wait for aggregate device to become ready before starting IOProc
        if !waitForDeviceReady(aggregateID, timeout: 2.0) {
            ttdLog("[TurnThatDown] Aggregate device not ready for \(app.name), proceeding anyway")
        }

        logDeviceStreams(aggregateID, label: "Aggregate-\(app.name)")

        ttdLog("[TurnThatDown] About to create IOProc for \(app.name)")

        let appTap = AppTap(tapID: tapID, aggregateDeviceID: aggregateID, bundleID: app.id)
        appTap.volume = app.isMuted ? 0 : app.volume
        appTap.muted = app.isMuted
        appTap.outputDeviceUID = app.outputDeviceUID
        appTap.balance = app.balance
        appTap.eq.enabled = app.eqEnabled
        for (i, band) in app.eqBands.enumerated() {
            appTap.eq.setGain(band.gain, forBand: i)
        }

        // IOProc on aggregate: reads tap input, writes volume-scaled audio to output
        let ioBlock: AudioDeviceIOBlock = { [weak appTap] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let tap = appTap else { return }

            let inBufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outBufs = UnsafeMutableAudioBufferListPointer(outOutputData)

            let volume = tap.muted ? Float(0.0) : tap.volume
            let balance = tap.balance // -1.0 left, 0 center, 1.0 right

            // Track peak audio level from input
            var peak: Float = 0
            for i in 0..<inBufs.count {
                let b = inBufs[i]
                if let data = b.mData {
                    let floats = data.assumingMemoryBound(to: Float32.self)
                    let totalSamples = Int(b.mDataByteSize) / MemoryLayout<Float32>.size
                    for s in 0..<totalSamples {
                        let absVal = abs(floats[s])
                        if absVal > peak { peak = absVal }
                    }
                }
            }
            tap.audioLevel = tap.audioLevel * 0.7 + peak * 0.3

            // Zero all output first
            for i in 0..<outBufs.count {
                if let d = outBufs[i].mData { memset(d, 0, Int(outBufs[i].mDataByteSize)) }
            }

            // Calculate per-channel gain from balance
            // balance=0: both 1.0, balance=-1: L=1.0 R=0.0, balance=1: L=0.0 R=1.0
            let leftGain = volume * min(1.0, 1.0 - balance)
            let rightGain = volume * min(1.0, 1.0 + balance)

            // Copy input -> output with volume and balance scaling
            // When input has more buffers than output, tap data is in the LAST buffers
            let inputOffset = max(0, inBufs.count - outBufs.count)
            for i in 0..<outBufs.count {
                let inBuf = inBufs[inputOffset + i]
                let outBuf = outBufs[i]
                guard let inData = inBuf.mData, let outData = outBuf.mData else { continue }
                let copySize = Int(min(inBuf.mDataByteSize, outBuf.mDataByteSize))

                // Determine channel gain: even index = left, odd = right
                let channelGain = (i % 2 == 0) ? leftGain : rightGain

                let outF = outData.assumingMemoryBound(to: Float32.self)
                let count = copySize / MemoryLayout<Float32>.size

                if channelGain == 1.0 && balance == 0 {
                    memcpy(outData, inData, copySize)
                } else if channelGain > 0 {
                    let inF = inData.assumingMemoryBound(to: Float32.self)
                    for j in 0..<count { outF[j] = inF[j] * channelGain }
                }

                // Apply EQ
                if tap.eq.enabled, channelGain > 0 {
                    tap.eq.processBuffer(outF, frameCount: count, channelIndex: i % 2)
                }

                // Soft clip to prevent harsh distortion when volume > 1.0 or EQ boost
                if channelGain > 1.0 || tap.eq.enabled {
                    for j in 0..<count {
                        let x = outF[j]
                        if x > 1.0 { outF[j] = 1.0 - 1.0 / (x + 1.0) }
                        else if x < -1.0 { outF[j] = -1.0 + 1.0 / (-x + 1.0) }
                    }
                }
            }
        }

        let ioQueue = DispatchQueue(label: "com.turnthatdown.io.\(app.id)", qos: .userInteractive)
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, ioBlock)
        guard createStatus == noErr else {
            ttdLog("[TurnThatDown] Failed to create IOProc for \(app.name): \(createStatus)")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }
        appTap.ioProcID = ioProcID

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            ttdLog("[TurnThatDown] Failed to start IOProc for \(app.name): \(startStatus)")
            if let pid = ioProcID { AudioDeviceDestroyIOProcID(aggregateID, pid) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        ttdLog("[TurnThatDown] Per-app volume active for \(app.name)")
        activeTaps[app.id] = appTap
    }

    // MARK: - Helpers

    private func getDefaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, &uid) == noErr else {
            return nil
        }
        return uid as String
    }

    private func waitForDeviceReady(_ deviceID: AudioDeviceID, timeout: TimeInterval) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isAlive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive) == noErr, isAlive != 0 {
                ttdLog("[TurnThatDown] Device \(deviceID) is ready")
                return true
            }
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }
        return false
    }

    // MARK: - Diagnostics

    private func logDeviceStreams(_ deviceID: AudioDeviceID, label: String) {
        for (scopeName, scope) in [("output", kAudioObjectPropertyScopeOutput), ("input", kAudioObjectPropertyScopeInput)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
                ttdLog("[TurnThatDown] \(label) has no \(scopeName) streams")
                continue
            }
            let streamCount = Int(size) / MemoryLayout<AudioStreamID>.size
            var streamIDs = [AudioStreamID](repeating: 0, count: streamCount)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streamIDs) == noErr else { continue }

            for (idx, streamID) in streamIDs.enumerated() {
                var fmtAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyPhysicalFormat,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var fmt = AudioStreamBasicDescription()
                var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                if AudioObjectGetPropertyData(streamID, &fmtAddr, 0, nil, &fmtSize, &fmt) == noErr {
                    ttdLog("[TurnThatDown] \(label) \(scopeName) stream[\(idx)]: sr=\(fmt.mSampleRate) ch=\(fmt.mChannelsPerFrame) bits=\(fmt.mBitsPerChannel) fmt=\(String(format: "0x%X", fmt.mFormatID)) flags=\(String(format: "0x%X", fmt.mFormatFlags))")
                }
            }
        }
    }

    // MARK: - Stale Device Cleanup

    private func cleanupStaleAggregateDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return }

        for deviceID in deviceIDs {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name) == noErr else { continue }

            if (name as String).hasPrefix("TurnThatDown-") {
                ttdLog("[TurnThatDown] Cleaning up stale aggregate device: \(name) (ID: \(deviceID))")
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    // MARK: - Tap Removal

    private func removeTap(for bundleID: String) {
        guard let tap = activeTaps.removeValue(forKey: bundleID) else { return }
        if let ioProcID = tap.ioProcID {
            AudioDeviceStop(tap.aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(tap.aggregateDeviceID, ioProcID)
        }
        AudioHardwareDestroyAggregateDevice(tap.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(tap.tapID)
        ttdLog("[TurnThatDown] Removed tap for \(bundleID)")
    }

    private func removeAllTaps() {
        for bundleID in Array(activeTaps.keys) {
            removeTap(for: bundleID)
        }
    }
}
