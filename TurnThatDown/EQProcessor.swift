import Accelerate
import Foundation

// 5-band parametric EQ using biquad filters
// Bands: 60Hz (low shelf), 230Hz, 910Hz, 3.6kHz, 14kHz (high shelf)
// Each band has gain in dB (-12 to +12)

struct EQBand {
    let frequency: Float
    let label: String
    var gain: Float = 0 // dB, -24 to +24
    let isShelf: Bool
}

final class EQProcessor {
    static let defaultBands: [EQBand] = [
        EQBand(frequency: 150, label: "Bass", gain: 0, isShelf: true),
        EQBand(frequency: 400, label: "Low", gain: 0, isShelf: false),
        EQBand(frequency: 1000, label: "Mid", gain: 0, isShelf: false),
        EQBand(frequency: 3500, label: "High", gain: 0, isShelf: false),
        EQBand(frequency: 12000, label: "Air", gain: 0, isShelf: true),
    ]

    var bands: [EQBand]
    var enabled: Bool = true
    private var sampleRate: Float = 48000

    // Biquad filter state per channel (stereo = 2 channels)
    // Each band has 5 coefficients: b0, b1, b2, a1, a2
    // State: 2 delay elements per band per channel
    private var coefficients: [[Float]] = [] // [band][5 coeffs]
    private var stateL: [[Float]] = [] // [band][2 delay elements]
    private var stateR: [[Float]] = [] // [band][2 delay elements]

    init(sampleRate: Float = 48000) {
        self.sampleRate = sampleRate
        self.bands = EQProcessor.defaultBands
        recalculateCoefficients()
    }

    func setSampleRate(_ rate: Float) {
        guard rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        recalculateCoefficients()
    }

    func setGain(_ gain: Float, forBand index: Int) {
        guard index >= 0, index < bands.count else { return }
        bands[index].gain = max(-24, min(24, gain))
        recalculateCoefficient(for: index)
    }

    func reset() {
        for i in 0..<bands.count {
            bands[i].gain = 0
        }
        recalculateCoefficients()
        resetState()
    }

    var isFlat: Bool {
        bands.allSatisfy { abs($0.gain) < 0.1 }
    }

    // Process non-interleaved stereo float audio in-place
    func processBuffer(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int, channelIndex: Int) {
        guard enabled, !isFlat else { return }

        for bandIdx in 0..<bands.count {
            guard abs(bands[bandIdx].gain) > 0.1 else { continue }

            let c = coefficients[bandIdx]
            let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]

            var z1: Float
            var z2: Float
            if channelIndex == 0 {
                z1 = stateL[bandIdx][0]
                z2 = stateL[bandIdx][1]
            } else {
                z1 = stateR[bandIdx][0]
                z2 = stateR[bandIdx][1]
            }

            for i in 0..<frameCount {
                let input = buffer[i]
                let output = b0 * input + z1
                z1 = b1 * input - a1 * output + z2
                z2 = b2 * input - a2 * output
                buffer[i] = output
            }

            if channelIndex == 0 {
                stateL[bandIdx][0] = z1
                stateL[bandIdx][1] = z2
            } else {
                stateR[bandIdx][0] = z1
                stateR[bandIdx][1] = z2
            }
        }
    }

    // MARK: - Biquad coefficient calculation

    private func recalculateCoefficients() {
        coefficients = []
        stateL = []
        stateR = []
        for i in 0..<bands.count {
            coefficients.append([1, 0, 0, 0, 0]) // passthrough
            stateL.append([0, 0])
            stateR.append([0, 0])
            recalculateCoefficient(for: i)
        }
    }

    private func resetState() {
        for i in 0..<bands.count {
            stateL[i] = [0, 0]
            stateR[i] = [0, 0]
        }
    }

    private func recalculateCoefficient(for index: Int) {
        let band = bands[index]
        let gain = band.gain
        guard abs(gain) > 0.1 else {
            // Passthrough
            if index < coefficients.count {
                coefficients[index] = [1, 0, 0, 0, 0]
            }
            return
        }

        let A = powf(10, gain / 40.0) // sqrt of linear gain
        let w0 = 2.0 * Float.pi * band.frequency / sampleRate
        let cosW0 = cosf(w0)
        let sinW0 = sinf(w0)

        var b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float

        if band.isShelf {
            if band.frequency < 500 {
                // Low shelf
                let alpha = sinW0 / 2.0 * sqrtf(2.0) // Q=0.707
                let sqrtA = sqrtf(A)
                a0 = (A + 1) + (A - 1) * cosW0 + 2 * sqrtA * alpha
                b0 = A * ((A + 1) - (A - 1) * cosW0 + 2 * sqrtA * alpha)
                b1 = 2 * A * ((A - 1) - (A + 1) * cosW0)
                b2 = A * ((A + 1) - (A - 1) * cosW0 - 2 * sqrtA * alpha)
                a1 = -2 * ((A - 1) + (A + 1) * cosW0)
                a2 = (A + 1) + (A - 1) * cosW0 - 2 * sqrtA * alpha
            } else {
                // High shelf
                let alpha = sinW0 / 2.0 * sqrtf(2.0)
                let sqrtA = sqrtf(A)
                a0 = (A + 1) - (A - 1) * cosW0 + 2 * sqrtA * alpha
                b0 = A * ((A + 1) + (A - 1) * cosW0 + 2 * sqrtA * alpha)
                b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
                b2 = A * ((A + 1) + (A - 1) * cosW0 - 2 * sqrtA * alpha)
                a1 = 2 * ((A - 1) - (A + 1) * cosW0)
                a2 = (A + 1) - (A - 1) * cosW0 - 2 * sqrtA * alpha
            }
        } else {
            // Peaking EQ, Q = 0.5 (very wide bandwidth for drastic control)
            let Q: Float = 0.5
            let alpha = sinW0 / (2 * Q)
            a0 = 1 + alpha / A
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A
        }

        // Normalize
        coefficients[index] = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}
