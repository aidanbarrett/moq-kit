import XCTest

@testable import MoQKit

final class TimelineResolverTests: XCTestCase {
    func testSelectionKeepsVideoEndSentinelAndAudioCoverage() {
        let entries = [
            DVR.TimelineEntry(group: 40, timestampUs: 10_000_000),
            DVR.TimelineEntry(group: 44, timestampUs: 12_000_000),
            DVR.TimelineEntry(group: 48, timestampUs: 14_000_000),
            DVR.TimelineEntry(group: 52, timestampUs: 16_000_000),
        ]

        XCTAssertEqual(
            DVR.TimelineIndex.slice(in: entries, start: 11_000_000, end: 15_000_000),
            [
                DVR.TimelineEntry(group: 40, timestampUs: 10_000_000),
                DVR.TimelineEntry(group: 44, timestampUs: 12_000_000),
                DVR.TimelineEntry(group: 48, timestampUs: 14_000_000),
                DVR.TimelineEntry(group: 52, timestampUs: 16_000_000),
            ])
    }

    func testAppendIgnoresOlderEntriesReplacesDuplicatesAndBoundsMemory() {
        var entries: [DVR.TimelineEntry] = []
        for entry in [
            DVR.TimelineEntry(group: 1, timestampUs: 1_000),
            DVR.TimelineEntry(group: 2, timestampUs: 2_000),
            DVR.TimelineEntry(group: 2, timestampUs: 2_100),
            DVR.TimelineEntry(group: 1, timestampUs: 1_100),
            DVR.TimelineEntry(group: 3, timestampUs: 3_000),
        ] {
            DVR.TimelineIndex.append(entry, to: &entries, limit: 2)
        }

        XCTAssertEqual(
            entries,
            [
                DVR.TimelineEntry(group: 2, timestampUs: 2_100),
                DVR.TimelineEntry(group: 3, timestampUs: 3_000),
            ]
        )
    }
}
