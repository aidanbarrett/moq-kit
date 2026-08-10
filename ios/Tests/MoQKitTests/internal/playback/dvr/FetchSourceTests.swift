import Foundation
import Moq
import XCTest

@testable import MoQKit

final class FetchSourceTests: XCTestCase {
    func testGenericCMAFMuxersEmitSeparateInitsAndDeterministicFragments() throws {
        let firstVideo = [
            Moq.MediaFrame(payload: Data("keyframe".utf8), timestampUs: 10_000_000, keyframe: true),
            Moq.MediaFrame(payload: Data("delta".utf8), timestampUs: 10_033_000, keyframe: false),
        ]
        let firstAudio = [
            Moq.MediaFrame(payload: Data([0x78, 0x00]), timestampUs: 10_020_000, keyframe: true)
        ]
        let videoMuxer = try Moq.CMAFMuxer(
            video: Moq.Video(
                codec: "vp09.00.10.08",
                description: nil,
                coded: nil,
                displayAspect: nil,
                bitrate: nil,
                framerate: 30,
                container: .legacy,
                timeline: nil
            ),
            originTimestampUs: 10_000_000
        )
        let audioMuxer = try Moq.CMAFMuxer(
            audio: Moq.Audio(
                codec: "opus",
                description: nil,
                sampleRate: 48_000,
                channelCount: 2,
                bitrate: nil,
                container: .legacy,
                timeline: nil
            ),
            originTimestampUs: 10_000_000
        )

        XCTAssertEqual(videoMuxer.initialization.subdata(in: 4..<8), Data("ftyp".utf8))
        XCTAssertEqual(audioMuxer.initialization.subdata(in: 4..<8), Data("ftyp".utf8))
        XCTAssertEqual(
            try videoMuxer.fragment(sequence: 8, frames: firstVideo).subdata(in: 4..<8),
            Data("moof".utf8)
        )
        XCTAssertEqual(
            try audioMuxer.fragment(sequence: 3, frames: firstAudio).subdata(in: 4..<8),
            Data("moof".utf8)
        )
    }

    func testCursorSkipsMissingAndEmptyGroupsWithinRequestedRange() async throws {
        let requestedGroups = RequestedGroups()
        let expectedFrame = Moq.MediaFrame(
            payload: Data([0x01, 0x02]),
            timestampUs: 2_000,
            keyframe: true
        )
        let fetcher = DVR.MediaGroupFetcher { _, sequence, _ in
            await requestedGroups.append(sequence)
            switch sequence {
            case 4, 7:
                throw MoqError.NotFound(message: "group was not retained")
            case 5:
                return []
            case 6:
                return [expectedFrame]
            default:
                XCTFail("Unexpected group \(sequence)")
                return []
            }
        }
        var cursor = DVR.TrackCursor(
            name: "video",
            groups: 4...7,
            container: .loc,
            fetcher: fetcher
        )

        let group = try await cursor.next()

        XCTAssertEqual(group?.frames, [expectedFrame])
        XCTAssertEqual(group?.groupSequence, 6)
        let end = try await cursor.next()
        XCTAssertNil(end)
        let groups = await requestedGroups.values
        XCTAssertEqual(Set(groups), Set([4, 5, 6, 7]))
    }

    func testCursorPrefetchesGroupsConcurrentlyAndDrainsThemInOrder() async throws {
        let concurrency = FetchConcurrency()
        let fetcher = DVR.MediaGroupFetcher { _, sequence, _ in
            await concurrency.started()
            try await Task.sleep(nanoseconds: 100_000_000)
            await concurrency.finished()
            return [
                Moq.MediaFrame(
                    payload: Data([UInt8(sequence)]),
                    timestampUs: sequence * 1_000,
                    keyframe: true
                )
            ]
        }
        var cursor = DVR.TrackCursor(
            name: "video",
            groups: 1...4,
            container: .loc,
            fetcher: fetcher,
            prefetchLimit: 4
        )
        defer { cursor.cancel() }

        var fetched: [DVR.FetchGroup] = []
        while let group = try await cursor.next() {
            fetched.append(group)
        }

        XCTAssertEqual(fetched.map(\.groupSequence), [1, 2, 3, 4])
        XCTAssertEqual(fetched.map { $0.frames[0].timestampUs }, [1_000, 2_000, 3_000, 4_000])
        let maximum = await concurrency.maximum
        XCTAssertGreaterThan(maximum, 1)
    }

    func testCursorReturnsEveryFrameInEachVideoGroup() async throws {
        let fetcher = DVR.MediaGroupFetcher { _, sequence, _ in
            switch sequence {
            case 10:
                return [
                    Moq.MediaFrame(payload: Data([0]), timestampUs: 10_000, keyframe: true),
                    Moq.MediaFrame(payload: Data([1]), timestampUs: 10_033, keyframe: false),
                    Moq.MediaFrame(payload: Data([2]), timestampUs: 10_066, keyframe: false),
                ]
            case 11:
                return [
                    Moq.MediaFrame(payload: Data([3]), timestampUs: 11_000, keyframe: true)
                ]
            default:
                XCTFail("Unexpected group \(sequence)")
                return []
            }
        }
        var cursor = DVR.TrackCursor(
            name: "video",
            groups: 10...11,
            container: .loc,
            fetcher: fetcher,
            prefetchLimit: 2
        )
        defer { cursor.cancel() }

        var fetched: [DVR.FetchGroup] = []
        while let group = try await cursor.next() {
            fetched.append(group)
        }

        XCTAssertEqual(fetched.map(\.groupSequence), [10, 11])
        XCTAssertEqual(fetched.map(\.frames.count), [3, 1])
        XCTAssertEqual(
            fetched.flatMap { $0.frames.map(\.payload) },
            [Data([0]), Data([1]), Data([2]), Data([3])]
        )
    }
}

private actor RequestedGroups {
    private(set) var values: [UInt64] = []

    func append(_ sequence: UInt64) {
        values.append(sequence)
    }
}

private actor FetchConcurrency {
    private(set) var maximum = 0
    private var current = 0

    func started() {
        current += 1
        maximum = max(maximum, current)
    }

    func finished() {
        current -= 1
    }
}
