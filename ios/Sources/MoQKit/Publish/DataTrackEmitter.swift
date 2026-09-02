import CoreMedia
import Foundation
import Moq

/// Push-based source for publishing app-defined binary messages on an object track.
///
/// Create one emitter per published data track, hand it to ``Publisher/addDataTrack(name:source:)``,
/// then keep a reference and call ``send(_:)`` whenever your app has a new payload.
public final class DataTrackEmitter: @unchecked Sendable {
    private var producer: Moq.TrackProducer?
    private var clock: PublisherClock?
    private var stopped = false

    /// Creates an emitter that can be attached to a published data track.
    public init() {}

    internal func attach(_ producer: Moq.TrackProducer, clock: PublisherClock) {
        self.clock = clock
        self.producer = producer
    }

    internal func detach() {
        stopped = true
        producer = nil
        clock = nil
    }

    /// Publishes one object stamped at emission time on the broadcast timeline.
    ///
    /// If the track has not started yet, or has already stopped, this is a no-op.
    public func send(_ data: Data) throws {
        guard !stopped, let producer else { return }
        // Stamp against the publisher clock so data frames share the epoch of the
        // broadcast's media tracks.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let timestampUs = clock?.timestampUs(from: now) ?? 0
        try producer.writeFrame(data, timestampUs: timestampUs)
    }

    /// Returns the timestamp for a capture presentation time on the broadcast's shared media
    /// timeline, using the same epoch as media-track frame timestamps.
    ///
    /// Returns `nil` until the broadcast epoch exists or while the emitter is detached. This
    /// method never establishes the epoch itself.
    public func mediaTimestampUs(from presentationTime: CMTime) -> UInt64? {
        guard !stopped else { return nil }
        return clock?.peekTimestampUs(from: presentationTime)
    }

    /// Publishes one object stamped with an explicit timestamp on the broadcast timeline.
    ///
    /// Use the value from ``mediaTimestampUs(from:)`` to co-time the object with a media frame.
    /// If the track has not started yet, or has already stopped, this is a no-op.
    public func send(_ data: Data, timestampUs: UInt64) throws {
        guard !stopped, let producer else { return }
        try producer.writeFrame(data, timestampUs: timestampUs)
    }
}
