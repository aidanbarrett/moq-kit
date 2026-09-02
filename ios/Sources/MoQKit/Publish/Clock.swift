import CoreMedia

/// A thread-safe clock that converts presentation timestamps to microseconds
/// relative to the first frame received across all tracks.
///
/// All tracks in a ``Publisher`` share the same `PublisherClock` instance so that
/// audio and video timestamps are aligned to a common epoch.
final class PublisherClock: @unchecked Sendable {
    private var epoch: CMTime?
    private let lock = UnfairLock()

    /// Convert a presentation timestamp to microseconds relative to stream start.
    ///
    /// The first call establishes the epoch and returns `0`. Subsequent calls
    /// return the offset from that epoch.
    func timestampUs(from pts: CMTime) -> UInt64 {
        lock.withLock {
            guard let epoch else {
                self.epoch = pts
                return 0
            }
            return Self.timestampUs(from: pts, relativeTo: epoch)
        }
    }

    /// Returns a presentation timestamp relative to the current epoch without establishing it.
    ///
    /// The epoch must remain the first media frame seen across all tracks. Data tracks may only
    /// read it: allowing an early data-track call to establish a later epoch would clamp earlier
    /// media frames to zero and corrupt the broadcast timeline.
    func peekTimestampUs(from pts: CMTime) -> UInt64? {
        lock.withLock {
            guard let epoch else { return nil }
            return Self.timestampUs(from: pts, relativeTo: epoch)
        }
    }

    /// Reset the clock for restarting a broadcast.
    func reset() {
        lock.withLock {
            epoch = nil
        }
    }

    private static func timestampUs(from pts: CMTime, relativeTo epoch: CMTime) -> UInt64 {
        let delta = CMTimeSubtract(pts, epoch)
        let us = CMTimeConvertScale(delta, timescale: 1_000_000, method: .default)
        return UInt64(max(0, us.value))
    }
}
