import Foundation
import Moq
import os

extension DVR {
    final class SegmentCoordinator: @unchecked Sendable {
        private struct Key: Hashable {
            let kind: DVR.MediaKind
            let index: Int
        }

        let plan: DVR.HLSPlan
        let videoInitialization: Data
        let audioInitialization: Data

        private let video: DVR.FetchTrack
        private let audio: DVR.FetchTrack
        private let fetcher: DVR.MediaGroupFetcher
        private let videoMuxer: Moq.CMAFMuxer
        private let audioMuxer: Moq.CMAFMuxer
        private struct State {
            var tasks: [Key: Task<Data, Error>] = [:]
            var stopped = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        init(
            plan: DVR.HLSPlan,
            video: DVR.FetchTrack,
            audio: DVR.FetchTrack,
            fetcher: DVR.MediaGroupFetcher
        ) throws {
            guard case .video(let videoConfig) = video.configuration,
                case .audio(let audioConfig) = audio.configuration
            else {
                throw DVR.PlaybackError.invalidTrackConfiguration
            }
            let videoMuxer = try Moq.CMAFMuxer(
                video: videoConfig,
                originTimestampUs: plan.originTimestampUs
            )
            let audioMuxer = try Moq.CMAFMuxer(
                audio: audioConfig,
                originTimestampUs: plan.originTimestampUs
            )
            self.plan = plan
            self.video = video
            self.audio = audio
            self.fetcher = fetcher
            self.videoMuxer = videoMuxer
            self.audioMuxer = audioMuxer
            self.videoInitialization = videoMuxer.initialization
            self.audioInitialization = audioMuxer.initialization
        }

        func segment(kind: DVR.MediaKind, index: Int) async throws -> Data {
            guard plan.segments.indices.contains(index) else {
                throw DVR.PlaybackError.segmentUnavailable(kind, index)
            }
            let key = Key(kind: kind, index: index)
            let segment = plan.segments[index]
            let video = video
            let audio = audio
            let fetcher = fetcher
            let videoMuxer = videoMuxer
            let audioMuxer = audioMuxer
            let task = try state.withLock { state -> Task<Data, Error> in
                guard !state.stopped else { throw CancellationError() }
                if let task = state.tasks[key] {
                    return task
                }
                let task = Task.detached(priority: .userInitiated) {
                    let started = ContinuousClock.now
                    let data: Data
                    switch kind {
                    case .video:
                        let frames = try await fetcher.fetch(
                            video.name,
                            segment.videoGroup,
                            video.container
                        )
                        guard !frames.isEmpty else {
                            throw DVR.PlaybackError.segmentUnavailable(.video, index)
                        }
                        data = try videoMuxer.fragment(
                            sequence: UInt32(clamping: index + 1),
                            frames: frames
                        )
                        KitLogger.dvr.debug(
                            "DVR HLS video segment ready index=\(index) group=\(segment.videoGroup) frames=\(frames.count) bytes=\(data.count) elapsedMs=\(started.duration(to: .now).milliseconds)"
                        )
                    case .audio:
                        var cursor = DVR.TrackCursor(
                            name: audio.name,
                            groups: segment.audioGroups,
                            container: audio.container,
                            fetcher: fetcher
                        )
                        defer { cursor.cancel() }
                        var frames: [Moq.MediaFrame] = []
                        var retainedGroups = 0
                        while let group = try await cursor.next() {
                            retainedGroups += 1
                            frames.append(
                                contentsOf: group.frames.lazy.filter {
                                    $0.timestampUs >= segment.startTimestampUs
                                        && $0.timestampUs < segment.endTimestampUs
                                })
                        }
                        guard !frames.isEmpty else {
                            throw DVR.PlaybackError.segmentUnavailable(.audio, index)
                        }
                        data = try audioMuxer.fragment(
                            sequence: UInt32(clamping: index + 1),
                            frames: frames
                        )
                        KitLogger.dvr.debug(
                            "DVR HLS audio segment ready index=\(index) requestedGroups=\(segment.audioGroups.lowerBound)...\(segment.audioGroups.upperBound) retainedGroups=\(retainedGroups) frames=\(frames.count) bytes=\(data.count) elapsedMs=\(started.duration(to: .now).milliseconds)"
                        )
                    }
                    return data
                }
                state.tasks[key] = task
                return task
            }

            do {
                return try await task.value
            } catch {
                state.withLock { $0.tasks[key] = nil }
                throw error
            }
        }

        func cancel() {
            let tasks = state.withLock { state in
                state.stopped = true
                let tasks = Array(state.tasks.values)
                state.tasks.removeAll()
                return tasks
            }
            for task in tasks {
                task.cancel()
            }
        }
    }
}
