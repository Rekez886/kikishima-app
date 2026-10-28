import AVFoundation
import Foundation

/// A small energy VAD with hysteresis and hangover.
///
/// It deliberately runs beside the transcriber instead of inside SpeechAnalyzer:
/// Apple's SpeechDetector gates transcription when attached, and dropping quiet
/// speech is worse than spending a little power on silence. This detector only
/// reports pauses long enough to justify cutting the agreed caption prefix at
/// an acoustic boundary; it never touches ASR finalization.
struct SpeechActivityDetector {
    enum Event: Equatable {
        case started
        case ended
    }

    // Conservative for meeting audio: a quiet talker should not be mistaken for
    // silence, and a noisy room may simply keep B disabled until the max cap.
    var startThresholdDB: Double = -55
    var endThresholdDB: Double = -62
    var startHangover: TimeInterval = 0.12
    var endHangover: TimeInterval = 0.40

    private(set) var isSpeaking = false
    private var above = 0.0
    private var below = 0.0

    mutating func process(levelDB: Double, duration: TimeInterval) -> Event? {
        guard duration > 0, levelDB.isFinite else { return nil }
        if isSpeaking {
            if levelDB < endThresholdDB {
                below += duration
            } else {
                below = 0
            }
            if below >= endHangover {
                isSpeaking = false
                above = 0
                below = 0
                return .ended
            }
        } else {
            if levelDB > startThresholdDB {
                above += duration
            } else {
                above = 0
            }
            if above >= startHangover {
                isSpeaking = true
                above = 0
                below = 0
                return .started
            }
        }
        return nil
    }

    mutating func reset() {
        isSpeaking = false
        above = 0
        below = 0
    }

    /// RMS level in dBFS. Returns nil for a format that is not float PCM.
    static func levelDB(_ buffer: AVAudioPCMBuffer) -> Double? {
        guard let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        if buffer.format.isInterleaved {
            let samples = data[0]
            var loudest = 0.0
            for channel in 0..<channels {
                var sum = 0.0
                for frame in 0..<frames {
                    let sample = Double(samples[frame * channels + channel])
                    guard sample.isFinite else { continue }
                    sum += sample * sample
                }
                loudest = max(loudest, (sum / Double(frames)).squareRoot())
            }
            return 20 * log10(max(loudest, 1e-7))
        }
        var loudest = 0.0
        for channel in 0..<channels {
            let samples = data[channel]
            var sum = 0.0
            for frame in 0..<frames {
                let sample = Double(samples[frame])
                guard sample.isFinite else { continue }
                sum += sample * sample
            }
            loudest = max(loudest, (sum / Double(frames)).squareRoot())
        }
        return 20 * log10(max(loudest, 1e-7))
    }
}
