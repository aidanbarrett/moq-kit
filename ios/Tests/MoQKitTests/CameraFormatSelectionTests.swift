import AVFoundation
import XCTest

@testable import MoQKit

final class CameraFormatSelectionTests: XCTestCase {
    private let formats = [
        CameraFormatCandidate(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 30),
        CameraFormatCandidate(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 60),
        CameraFormatCandidate(width: 1920, height: 1080, minFrameRate: 120, maxFrameRate: 240),
        CameraFormatCandidate(width: 1280, height: 720, minFrameRate: 1, maxFrameRate: 240),
        CameraFormatCandidate(width: 3840, height: 2160, minFrameRate: 1, maxFrameRate: 30),
    ]

    func testExactDimensionsWithTheLowestCeilingContainingTheRate() {
        XCTAssertEqual(
            CameraFormatSelection.index(of: formats, width: 1920, height: 1080, frameRate: 30), 0)
        XCTAssertEqual(
            CameraFormatSelection.index(of: formats, width: 1920, height: 1080, frameRate: 50), 1)
        XCTAssertEqual(
            CameraFormatSelection.index(of: formats, width: 3840, height: 2160, frameRate: 30), 4)
    }

    func testAHighSpeedRangeAboveTheRateIsNotAMatch() {
        // 1080p at 100 fps: only the 120–240 range is that fast, and it does not contain 100.
        XCTAssertNil(
            CameraFormatSelection.index(of: formats, width: 1920, height: 1080, frameRate: 100))
    }

    func testNearbyDimensionsNeverSubstitute() {
        XCTAssertNil(
            CameraFormatSelection.index(of: formats, width: 1600, height: 900, frameRate: 30))
        XCTAssertNil(
            CameraFormatSelection.index(of: formats, width: 3840, height: 2160, frameRate: 60))
    }

    func testInvalidRatesSelectNothing() {
        XCTAssertNil(CameraFormatSelection.index(of: formats, width: 1920, height: 1080, frameRate: 0))
        XCTAssertNil(CameraFormatSelection.index(of: formats, width: 1920, height: 1080, frameRate: .nan))
    }

    func testFrameDurationIsAnExactRational() {
        let thirty = CameraFormatSelection.frameDuration(for: 30)
        XCTAssertEqual(thirty.value, 1000)
        XCTAssertEqual(thirty.timescale, 30_000)
        XCTAssertEqual(CMTimeGetSeconds(thirty) * 30, 1, accuracy: 1e-12)
        let fifty = CameraFormatSelection.frameDuration(for: 50)
        XCTAssertEqual(fifty.timescale, 50_000)
    }

    func testCameraDefaultsStayCompatible() {
        let camera = Camera()
        XCTAssertEqual(camera.deviceTypes, [.builtInWideAngleCamera])
        XCTAssertNil(camera.maxFrameRate)
        XCTAssertEqual(Camera(deviceTypes: []).deviceTypes, [.builtInWideAngleCamera])
    }
}
