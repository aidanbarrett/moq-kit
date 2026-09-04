import CoreMedia
@testable import MoQKit
import XCTest

final class AudioPacketTimelineTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let opusPacket: Int64 = 960
    /// The iPhone's 48 kHz capture buffer: not a whole number of 20 ms packets.
    private let captureFrames = 1104

    private func captureTime(_ bufferIndex: Int) -> CMTime {
        CMTime(value: CMTimeValue(bufferIndex * captureFrames), timescale: 48_000)
    }

    func testPacketsAreSpacedExactlyOnePacketApartAcrossCarriedSamples() {
        var timeline = AudioPacketTimeline(outputSampleRate: sampleRate, samplesPerPacket: opusPacket)
        var packetTimes: [CMTime] = []
        var carried = 0
        for bufferIndex in 0..<20 {
            XCTAssertFalse(timeline.observeInput(
                presentationTime: captureTime(bufferIndex),
                frameCount: captureFrames,
                sampleRate: sampleRate
            ))
            carried += captureFrames
            while carried >= Int(opusPacket) {
                packetTimes.append(timeline.nextPacketTime())
                carried -= Int(opusPacket)
            }
        }
        XCTAssertEqual(packetTimes.count, 23)
        for (index, time) in packetTimes.enumerated() {
            XCTAssertEqual(
                CMTimeGetSeconds(time), Double(index) * 0.020, accuracy: 1e-9,
                "packet \(index) drifted off the 20 ms grid"
            )
        }
    }

    func testSmallCaptureJitterDoesNotReanchor() {
        var timeline = AudioPacketTimeline(outputSampleRate: sampleRate, samplesPerPacket: opusPacket)
        timeline.observeInput(presentationTime: captureTime(0), frameCount: captureFrames, sampleRate: sampleRate)
        let jittered = CMTimeAdd(captureTime(1), CMTime(value: 5, timescale: 1000))
        XCTAssertFalse(timeline.observeInput(
            presentationTime: jittered, frameCount: captureFrames, sampleRate: sampleRate
        ))
        _ = timeline.nextPacketTime()
        XCTAssertEqual(CMTimeGetSeconds(timeline.nextPacketTime()), 0.020, accuracy: 1e-9)
    }

    func testCaptureGapReanchorsAndPreservesTheGap() {
        var timeline = AudioPacketTimeline(outputSampleRate: sampleRate, samplesPerPacket: opusPacket)
        timeline.observeInput(presentationTime: captureTime(0), frameCount: captureFrames, sampleRate: sampleRate)
        _ = timeline.nextPacketTime()

        let afterGap = CMTimeAdd(captureTime(1), CMTime(value: 500, timescale: 1000))
        XCTAssertTrue(timeline.observeInput(
            presentationTime: afterGap, frameCount: captureFrames, sampleRate: sampleRate
        ))
        XCTAssertEqual(
            CMTimeGetSeconds(timeline.nextPacketTime()), CMTimeGetSeconds(afterGap), accuracy: 1e-9
        )
    }

    func testFirstBufferAnchorsAtItsOwnTime() {
        var timeline = AudioPacketTimeline(outputSampleRate: sampleRate, samplesPerPacket: opusPacket)
        let start = CMTime(value: 123_456_789, timescale: 1_000_000_000)
        XCTAssertFalse(timeline.observeInput(
            presentationTime: start, frameCount: captureFrames, sampleRate: sampleRate
        ))
        XCTAssertEqual(CMTimeGetSeconds(timeline.nextPacketTime()), CMTimeGetSeconds(start), accuracy: 1e-9)
    }
}
