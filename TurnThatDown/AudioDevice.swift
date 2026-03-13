import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasOutput: Bool
    let hasInput: Bool
    let transportType: UInt32

    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    var iconName: String {
        if transportType == kAudioDeviceTransportTypeBluetooth ||
            transportType == kAudioDeviceTransportTypeBluetoothLE
        {
            return "headphones"
        } else if transportType == kAudioDeviceTransportTypeUSB {
            return "cable.connector"
        } else if transportType == kAudioDeviceTransportTypeHDMI ||
            transportType == kAudioDeviceTransportTypeDisplayPort
        {
            return "tv"
        } else if isBuiltIn {
            if hasInput && !hasOutput {
                return "mic"
            }
            return "laptopcomputer"
        } else if transportType == kAudioDeviceTransportTypeAggregate ||
            transportType == kAudioDeviceTransportTypeVirtual
        {
            return "rectangle.stack"
        }
        return "speaker.wave.2"
    }
}
