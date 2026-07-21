import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization
import os

/// ScreenCaptureKit fallback (contract §6): one `SCStream` carries both lanes
/// — `.audio` filtered to the target app ("Them") and `.microphone` ("Me") —
/// so both PTS ride one synchronization clock, preserving the primary path's
/// one-clock alignment property.
///
/// Used when tap/aggregate setup fails, or on explicit backend override.
/// Rides Screen Recording TCC, not System Audio Recording.
final class SCKEngine: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "SCKEngine")

    private let targetPID: pid_t
    private let micRing: RingBuffer
    private let sysRing: RingBuffer
    private let micGap: SilenceGapBox
    private let sysGap: SilenceGapBox
    private let micFormatBox: LaneFormatBox
    private let sysFormatBox: LaneFormatBox
    private let onStopped: @Sendable (CaptureStopReason) -> Void

    private var stream: SCStream?
    private let micQueue = DispatchQueue(label: "dev.collinsadi.saaa.sck.mic")
    private let sysQueue = DispatchQueue(label: "dev.collinsadi.saaa.sck.sys")
    private let screenQueue = DispatchQueue(label: "dev.collinsadi.saaa.sck.screen", qos: .utility)

    /// Per-lane PTS bookkeeping guarded by a mutex (handlers run on their own
    /// GCD queues — not RT threads, so a lock is acceptable here).
    private struct LaneClock {
        var firstPTS: Double?
        var expectedNextPTS: Double?
    }
    private let clocks = Mutex<(mic: LaneClock, sys: LaneClock)>((LaneClock(), LaneClock()))

    init(
        targetPID: pid_t,
        micRing: RingBuffer, sysRing: RingBuffer,
        micGap: SilenceGapBox, sysGap: SilenceGapBox,
        micFormatBox: LaneFormatBox, sysFormatBox: LaneFormatBox,
        onStopped: @escaping @Sendable (CaptureStopReason) -> Void
    ) {
        self.targetPID = targetPID
        self.micRing = micRing
        self.sysRing = sysRing
        self.micGap = micGap
        self.sysGap = sysGap
        self.micFormatBox = micFormatBox
        self.sysFormatBox = sysFormatBox
        self.onStopped = onStopped
    }

    func start() async throws {
        if !CGPreflightScreenCaptureAccess() {
            // First-ever grant requires an app relaunch — surfaced as an error
            // after the request so onboarding can explain the relaunch.
            CGRequestScreenCaptureAccess()
            throw CaptureError.screenRecordingPermissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.processID == targetPID }) else {
            throw CaptureError.targetProcessNotFound(targetPID)
        }
        guard let display = content.displays.first else {
            throw CaptureError.targetProcessNotFound(targetPID)
        }

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = nil
        // Video cannot be disabled — starve it and swallow its frames.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            Self.log.error("stopCapture failed: \(error, privacy: .public)")
        }
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .audio:
            ingest(sampleBuffer, ring: sysRing, gap: sysGap, otherGap: micGap,
                   formatBox: sysFormatBox, lane: \.sys, otherLane: \.mic)
        case .microphone:
            ingest(sampleBuffer, ring: micRing, gap: micGap, otherGap: sysGap,
                   formatBox: micFormatBox, lane: \.mic, otherLane: \.sys)
        case .screen:
            break // starved video, dropped by design
        @unknown default:
            break
        }
    }

    /// Copies buffer 0 into the lane ring (deinterleaved SCK audio: channel 0;
    /// interleaved: all channels), publishes the lane format on first buffer,
    /// and converts PTS gaps into output-rate silence so the two WAV timelines
    /// stay aligned even if SCK stops delivering buffers while an app is quiet.
    private func ingest(
        _ sampleBuffer: CMSampleBuffer,
        ring: RingBuffer,
        gap: SilenceGapBox,
        otherGap: SilenceGapBox,
        formatBox: LaneFormatBox,
        lane: WritableKeyPath<(mic: LaneClock, sys: LaneClock), LaneClock>,
        otherLane: WritableKeyPath<(mic: LaneClock, sys: LaneClock), LaneClock>
    ) {
        guard sampleBuffer.isValid,
              let formatDescription = sampleBuffer.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }

        let pts = sampleBuffer.presentationTimeStamp.seconds
        let frames = sampleBuffer.numSamples
        guard frames > 0 else { return }
        let rate = asbd.mSampleRate

        // PTS bookkeeping: mid-stream forward gaps become silence in THIS
        // lane, and on this lane's first buffer the cross-lane start offset
        // (both lanes' PTS ride one synchronizationClock) pads whichever lane
        // starts later, so the two WAV timelines share t=0.
        let padding: (mine: Double, other: Double)? = clocks.withLock { state in
            var laneClock = state[keyPath: lane]
            defer {
                laneClock.expectedNextPTS = pts + Double(frames) / rate
                state[keyPath: lane] = laneClock
            }
            if laneClock.firstPTS == nil {
                laneClock.firstPTS = pts
                guard let otherFirst = state[keyPath: otherLane].firstPTS else { return nil }
                let delta = pts - otherFirst
                // delta > 0: this lane starts later → pad it. delta < 0: the
                // other lane started later; pad it now (its early buffers are
                // already written, so the pad lands a hair late — bounded by
                // the few buffers delivered before this one).
                return delta > 0 ? (mine: delta, other: 0) : (mine: 0, other: -delta)
            }
            guard let expected = laneClock.expectedNextPTS else { return nil }
            let delta = pts - expected
            return delta > 0.05 ? (mine: delta, other: 0) : nil
        }
        if let padding {
            if padding.mine > 0 {
                gap.add(frames: Int(padding.mine * LanePipeline.outputSampleRate))
            }
            if padding.other > 0 {
                otherGap.add(frames: Int(padding.other * LanePipeline.outputSampleRate))
            }
        }

        do {
            try sampleBuffer.withAudioBufferList { ablPointer, _ in
                guard let first = ablPointer.first, let data = first.mData else { return }
                let channels = max(1, Int(first.mNumberChannels))
                formatBox.publish(LaneFormat(channels: channels, sampleRate: rate))
                let samples = Int(first.mDataByteSize) / MemoryLayout<Float32>.size
                ring.write(
                    data.assumingMemoryBound(to: Float32.self),
                    count: samples / channels * channels,
                    frameAlign: channels)
            }
        } catch {
            Self.log.error("withAudioBufferList failed: \(error, privacy: .public)")
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        Self.log.error("SCStream stopped: \(code) \(error, privacy: .public)")
        let reason: CaptureStopReason
        switch code {
        case -3821, -3801: // systemStoppedStream (permission lapse), userDeclined
            reason = .permissionRevoked
        default:
            reason = .failed(CaptureFailure(code: "sck-\(code)", detail: error.localizedDescription))
        }
        onStopped(reason)
    }
}
