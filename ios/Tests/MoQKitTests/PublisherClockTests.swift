import CoreMedia
@testable import MoQKit
import XCTest

final class PublisherClockTests: XCTestCase {
    func testPeekReturnsNilBeforeEpochAndMatchesMediaTimestampAfterEpochExists() throws {
        let clock = PublisherClock()
        let epoch = CMTime(value: 600, timescale: 600)
        let presentationTime = CMTime(value: 750, timescale: 600)

        XCTAssertNil(clock.peekTimestampUs(from: presentationTime))
        XCTAssertEqual(clock.timestampUs(from: epoch), 0)
        XCTAssertEqual(
            try XCTUnwrap(clock.peekTimestampUs(from: presentationTime)),
            clock.timestampUs(from: presentationTime)
        )
    }

    func testPeekDoesNotEstablishEpoch() {
        let clock = PublisherClock()
        let peekedTime = CMTime(value: 1_200, timescale: 600)
        let epoch = CMTime(value: 600, timescale: 600)
        let laterTime = CMTime(value: 612, timescale: 600)

        XCTAssertNil(clock.peekTimestampUs(from: peekedTime))
        XCTAssertEqual(clock.timestampUs(from: epoch), 0)
        XCTAssertEqual(clock.timestampUs(from: laterTime), 20_000)
    }

    func testPeekUsesSameSubsecondRoundingAsMediaTimestamp() throws {
        let clock = PublisherClock()
        let epoch = CMTime(value: 301, timescale: 600)
        let oneFiftiethSecondLater = CMTime(value: 313, timescale: 600)

        XCTAssertEqual(clock.timestampUs(from: epoch), 0)
        XCTAssertEqual(
            try XCTUnwrap(clock.peekTimestampUs(from: oneFiftiethSecondLater)),
            20_000
        )
        XCTAssertEqual(clock.timestampUs(from: oneFiftiethSecondLater), 20_000)
    }
}

final class DataTrackEmitterTimestampTests: XCTestCase {
    func testMediaTimestampReturnsNilWhenUnattached() {
        let emitter = DataTrackEmitter()

        XCTAssertNil(emitter.mediaTimestampUs(from: .zero))
    }
}
