import CoreMedia

/// Presentation times for encoded audio packets, counted in samples from an anchor rather than
/// copied from whichever capture buffer happened to complete the packet.
///
/// Capture buffers rarely hold a whole number of codec packets (an iPhone delivers 1104 frames at
/// 48 kHz against 960-frame Opus packets), so the converter carries samples across calls and a
/// packet's real start drifts up to one packet behind the buffer it was drained from. Stamping
/// packets with the buffer's PTS jittered them by up to 20 ms; a receiver that places audio by
/// timestamp then overwrites and zero-fills at every jitter step, which is audible as stutter.
///
/// Counting emitted packets from the first buffer's PTS keeps the timeline locked to the samples
/// actually encoded. A capture discontinuity larger than ``reanchorTolerance`` re-anchors the
/// timeline on the new buffer so a real gap is preserved instead of absorbed.
struct AudioPacketTimeline {
    let outputSampleRate: Double
    let samplesPerPacket: Int64
    let reanchorTolerance: CMTime

    private var anchor: CMTime?
    private var inputFramesConsumed: Int64 = 0
    private var packetsEmitted: Int64 = 0

    init(
        outputSampleRate: Double,
        samplesPerPacket: Int64,
        reanchorTolerance: CMTime = CMTime(value: 30, timescale: 1000)
    ) {
        self.outputSampleRate = outputSampleRate
        self.samplesPerPacket = samplesPerPacket
        self.reanchorTolerance = reanchorTolerance
    }

    /// Where the timeline expects the next input buffer to start; nil before the first buffer.
    var expectedInputTime: CMTime? {
        guard let anchor, let inputSampleRate else { return nil }
        return CMTimeAdd(
            anchor,
            CMTime(value: inputFramesConsumed, timescale: CMTimeScale(inputSampleRate))
        )
    }

    private var inputSampleRate: Double?

    /// Accounts for an input buffer. Returns true when the buffer did not follow the previous
    /// one and the timeline re-anchored on it; the caller should then discard any samples the
    /// converter still holds from before the discontinuity.
    @discardableResult
    mutating func observeInput(
        presentationTime: CMTime, frameCount: Int, sampleRate: Double
    ) -> Bool {
        let reanchored: Bool
        if let expected = expectedInputTime, inputSampleRate == sampleRate {
            let drift = CMTimeSubtract(presentationTime, expected)
            reanchored = CMTimeAbsoluteValue(drift) > reanchorTolerance
            if reanchored { reanchor(at: presentationTime) }
        } else {
            // The first buffer anchors the timeline; a format change re-anchors it.
            reanchored = anchor != nil
            reanchor(at: presentationTime)
        }
        inputSampleRate = sampleRate
        inputFramesConsumed += Int64(frameCount)
        return reanchored
    }

    /// The presentation time of the next packet drained from the converter.
    mutating func nextPacketTime() -> CMTime {
        let base = anchor ?? .zero
        let offset = CMTime(
            value: packetsEmitted * samplesPerPacket,
            timescale: CMTimeScale(outputSampleRate)
        )
        packetsEmitted += 1
        return CMTimeAdd(base, offset)
    }

    private mutating func reanchor(at time: CMTime) {
        anchor = time
        inputFramesConsumed = 0
        packetsEmitted = 0
    }
}
