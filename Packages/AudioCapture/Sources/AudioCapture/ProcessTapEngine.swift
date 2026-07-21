import CoreAudio
import Foundation
import os

/// Change signals the engine's HAL property listeners can raise. Delivered on
/// an arbitrary serial queue; the session hops them onto its actor.
enum TapEngineSignal: Sendable {
    case processListChanged
    case defaultInputChanged
    case targetRunningOutputChanged(Bool)
    case aggregateDied
    case compositionChanged
    case sampleRateOrFormatChanged
}

/// Owns the Core Audio objects of the primary capture path: the process tap,
/// the private mic+tap aggregate device, the RT IOProc, and the property
/// listeners. Created, driven, and torn down exclusively by `CaptureSession`.
///
/// Architecture (contract §1): one aggregate with the mic as sole sub-device
/// and clock master plus the tap (drift-compensated onto the mic clock), one
/// IOProc feeding two SPSC rings. Alignment is intrinsic — one device, one
/// clock, one callback timeline.
final class ProcessTapEngine {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "ProcessTapEngine")

    private let target: CaptureTarget
    private let micRing: RingBuffer
    private let sysRing: RingBuffer
    private let anchor: HostTimeAnchor

    private var processObjectID = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "dev.collinsadi.saaa.capture.listeners")

    /// Frozen at setup; the IO block captures a copy.
    private(set) var layout: StreamLayout?
    /// The mic device the aggregate was built around (pinned for the run).
    private(set) var micDeviceID = AudioObjectID(kAudioObjectUnknown)
    /// Setup breadcrumbs, persisted to diagnostics.txt with each recording.
    private(set) var diagnostics: [String] = []

    /// Debug: build the aggregate with ONLY the output device + tap (Apple's
    /// sample shape, no mic sub-device); both lanes then record the tap.
    /// Set via the harness `--tap-only` flag to isolate composition problems.
    static var debugTapOnly: Bool { AudioCaptureModule.debugTapOnlyComposition }

    private func diagnostic(_ line: String) {
        diagnostics.append(line)
        Self.log.info("\(line, privacy: .public)")
    }

    init(target: CaptureTarget, micRing: RingBuffer, sysRing: RingBuffer, anchor: HostTimeAnchor) {
        self.target = target
        self.micRing = micRing
        self.sysRing = sysRing
        self.anchor = anchor
    }

    /// Whether the target still exists (always true for the global tap).
    var isTargetProcessAlive: Bool {
        switch target {
        case .allSystemAudio:
            return true
        case .process(let pid):
            if HAL.processObject(for: pid) != nil { return true }
            // The app process may never have been a HAL client — it counts as
            // alive while any of its helpers still is.
            let members = (try? AudioProcessDirectory.snapshot()) ?? []
            return members.contains { ProcessTree.isDescendant($0.pid, of: pid) }
        }
    }

    /// Resolves the HAL process objects a `.process` target actually covers:
    /// the PID itself plus every descendant helper that is a HAL client.
    private static func tapMembers(for pid: pid_t) throws -> [AudioObjectID] {
        let entries = try AudioProcessDirectory.snapshot()
        let members = entries.filter { ProcessTree.isDescendant($0.pid, of: pid) }
        guard !members.isEmpty else { throw CaptureError.targetProcessNotFound(pid) }
        return members.map(\.id)
    }

    /// Runs contract §2 setup steps 2–12. On any failure, unwinds whatever was
    /// created and rethrows a typed `CaptureError` — no half-activated state.
    func setup(
        preferredMicDeviceID: AudioObjectID?,
        onSignal: @escaping @Sendable (TapEngineSignal) -> Void
    ) throws {
        do {
            try performSetup(preferredMicDeviceID: preferredMicDeviceID, onSignal: onSignal)
        } catch {
            teardown()
            throw error
        }
    }

    private func performSetup(
        preferredMicDeviceID: AudioObjectID?,
        onSignal: @escaping @Sendable (TapEngineSignal) -> Void
    ) throws {
        // Step 2 — resolve the HAL process objects the tap covers.
        let tapTargets: [AudioObjectID]
        switch target {
        case .process(let pid):
            tapTargets = try Self.tapMembers(for: pid)
            // Listener anchor: the app's own object if it is a HAL client,
            // else the first helper.
            processObjectID = HAL.processObject(for: pid) ?? tapTargets[0]
        case .allSystemAudio:
            tapTargets = []
            processObjectID = AudioObjectID(kAudioObjectUnknown)
        }

        // Step 3 — resolve and pin the mic device, and the default OUTPUT
        // device. The output device is essential: a process tap injects audio
        // on the output device's IO cycle, so the tap-bearing aggregate must
        // contain that device to tick the tap's clock domain. (Observed live:
        // a mic-only aggregate produced a tap stream of pure zeros advertising
        // the output device's 44.1 kHz while the aggregate ran at 48 kHz.)
        guard let mic = preferredMicDeviceID ?? HAL.defaultInputDevice(),
              let micUID = HAL.deviceUID(mic) else {
            throw CaptureError.micDeviceUnavailable
        }
        guard let output = HAL.defaultOutputDevice(),
              let outputUID = HAL.deviceUID(output) else {
            throw CaptureError.aggregateCreationFailed(kAudioHardwareBadDeviceError)
        }
        micDeviceID = mic
        // Combo device (e.g. AirPods) serving both directions: one sub-device
        // entry, no leading input streams to skip.
        let comboDevice = micUID == outputUID
        let leadingStreamsToSkip = comboDevice
            ? 0 : (try? HAL.inputStreams(output).count) ?? 0
        diagnostic("mic device \(mic) uid=\(micUID); output device \(output) uid=\(outputUID); combo=\(comboDevice) skipLeading=\(leadingStreamsToSkip)")

        // Step 4 — tap description: stereo mixdown, private, user keeps
        // hearing the call, process-scoped (follows processes across devices).
        // Global target = tap everything (exclude-nothing variant).
        let description: CATapDescription
        switch target {
        case .process:
            description = CATapDescription(stereoMixdownOfProcesses: tapTargets)
        case .allSystemAudio:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.name = "Saaa-tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isExclusive = false

        // Step 5 — create the tap.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        // Step 6 — authoritative tap identity + format from the tap object.
        guard let tapUID = HAL.readString(tapID, kAudioTapPropertyUID) else {
            throw CaptureError.tapCreationFailed(kAudioHardwareUnspecifiedError)
        }
        var tapFormat = AudioStreamBasicDescription()
        guard HAL.read(tapID, kAudioTapPropertyFormat, into: &tapFormat) == noErr,
              tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw CaptureError.unsupportedTapFormat
        }

        // Step 7 — the aggregate, fully composed at creation: the OUTPUT
        // device as clock master (drives the tap's injection cycle) plus the
        // mic drift-compensated onto that clock, tap in the tap list.
        // TapAutoStart MUST be true (Apple sample + AudioCap): without it the
        // aggregate never engages its taps — the tap stream exists but
        // delivers zeros forever, and the system-audio TCC prompt never
        // fires (verified live on this machine).
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
        if !comboDevice && !Self.debugTapOnly {
            subDevices.append([
                kAudioSubDeviceUIDKey: micUID,
                kAudioSubDeviceDriftCompensationKey: true,
            ])
        }
        if Self.debugTapOnly {
            diagnostic("DEBUG tap-only composition (no mic sub-device)")
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Saaa Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID)
        guard aggStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            throw CaptureError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = newAggregateID

        diagnostic("tap \(tapID) uid=\(tapUID) fmt=\(tapFormat.mSampleRate)Hz \(tapFormat.mChannelsPerFrame)ch")
        diagnostic("aggregate \(aggregateID) nominalRate=\(HAL.nominalSampleRate(aggregateID) ?? 0)")
        if let streams = try? HAL.inputStreams(aggregateID) {
            for (index, stream) in streams.enumerated() {
                let asbd = HAL.streamVirtualFormat(stream)
                diagnostic("input stream[\(index)] id=\(stream) \(asbd?.mSampleRate ?? 0)Hz \(asbd?.mChannelsPerFrame ?? 0)ch")
            }
        }

        // Step 8 — freeze the buffer-lane attribution; never guess.
        let frozenLayout: StreamLayout
        if Self.debugTapOnly {
            let streams = (try? HAL.inputStreams(aggregateID)) ?? []
            guard let last = streams.indices.last else { throw CaptureError.layoutAmbiguous }
            let channels = Int(HAL.streamVirtualFormat(streams[last])?.mChannelsPerFrame ?? 2)
            let rate = HAL.nominalSampleRate(aggregateID) ?? tapFormat.mSampleRate
            frozenLayout = StreamLayout(
                micBufferIndex: last, tapBufferIndex: last,
                micChannels: channels, tapChannels: channels,
                micSampleRate: rate, tapSampleRate: rate)
        } else {
            frozenLayout = try StreamLayout.catalog(
                aggregateID: aggregateID, tapFormat: tapFormat,
                leadingStreamsToSkip: leadingStreamsToSkip)
        }
        layout = frozenLayout
        diagnostic("layout mic[\(frozenLayout.micBufferIndex)] \(frozenLayout.micChannels)ch@\(frozenLayout.micSampleRate) tap[\(frozenLayout.tapBufferIndex)] \(frozenLayout.tapChannels)ch@\(frozenLayout.tapSampleRate)")

        // Step 10 — property listeners (step 9's allocations live in the session).
        registerListeners(onSignal: onSignal)

        // Step 11 — the RT IO block. Queue MUST be nil: the block runs
        // directly on the HAL RT thread. Everything it touches is resolved
        // into locals here; body is pointer math + memcpy + atomics only.
        let micRing = self.micRing
        let sysRing = self.sysRing
        let anchor = self.anchor
        let micIndex = frozenLayout.micBufferIndex
        let tapIndex = frozenLayout.tapBufferIndex
        let micChannels = max(1, frozenLayout.micChannels)
        let tapChannels = max(1, frozenLayout.tapChannels)
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, inInputTime, _, _ in
            let ts = inInputTime.pointee
            if ts.mHostTime != 0, anchor.raw.load(ordering: .relaxed) == 0 {
                anchor.raw.store(ts.mHostTime, ordering: .relaxed)
            }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            // Counts are rounded down to whole frames so a ring overrun can
            // never commit a partial frame (which would flip channel phase
            // for everything after it).
            if micIndex < abl.count, let base = abl[micIndex].mData {
                let samples = Int(abl[micIndex].mDataByteSize) / MemoryLayout<Float32>.size
                micRing.write(
                    base.assumingMemoryBound(to: Float32.self),
                    count: samples / micChannels * micChannels,
                    frameAlign: micChannels)
            }
            if tapIndex < abl.count, let base = abl[tapIndex].mData {
                let samples = Int(abl[tapIndex].mDataByteSize) / MemoryLayout<Float32>.size
                sysRing.write(
                    base.assumingMemoryBound(to: Float32.self),
                    count: samples / tapChannels * tapChannels,
                    frameAlign: tapChannels)
            }
        }
        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, nil, ioBlock)
        guard ioStatus == noErr, let procID = newIOProcID else {
            throw CaptureError.ioProcFailed(ioStatus)
        }
        ioProcID = procID

        // Step 12 — start. First-ever run fires the System Audio Recording
        // TCC prompt here.
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            throw CaptureError.ioProcFailed(startStatus)
        }
    }

    /// Contract §2 teardown steps 1–3 + 5–6 (the final drain, step 4, belongs
    /// to the session's drain task). Every OSStatus is log-and-continue so
    /// teardown always completes; safe to call at any point of partial setup.
    func teardown() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            logStatus(AudioDeviceStop(aggregateID, procID), "AudioDeviceStop")
            logStatus(AudioDeviceDestroyIOProcID(aggregateID, procID), "AudioDeviceDestroyIOProcID")
        }
        ioProcID = nil
        for entry in listeners {
            var address = entry.address
            logStatus(
                AudioObjectRemovePropertyListenerBlock(
                    entry.object, &address, listenerQueue, entry.block),
                "AudioObjectRemovePropertyListenerBlock")
        }
        listeners.removeAll()
        if aggregateID != kAudioObjectUnknown {
            // Aggregate before tap, always: destroying the tap first fires the
            // aggregate's TapList listener mid-teardown.
            logStatus(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            logStatus(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = kAudioObjectUnknown
        }
        layout = nil
    }

    private func registerListeners(onSignal: @escaping @Sendable (TapEngineSignal) -> Void) {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        listen(on: systemObject, selector: kAudioHardwarePropertyProcessObjectList) { _ in
            onSignal(.processListChanged)
        }
        listen(on: systemObject, selector: kAudioHardwarePropertyDefaultInputDevice) { _ in
            onSignal(.defaultInputChanged)
        }
        if processObjectID != kAudioObjectUnknown {
            listen(on: processObjectID, selector: kAudioProcessPropertyIsRunningOutput) { object in
                var running: UInt32 = 0
                _ = HAL.read(object, kAudioProcessPropertyIsRunningOutput, into: &running)
                onSignal(.targetRunningOutputChanged(running != 0))
            }
        }
        listen(on: aggregateID, selector: kAudioDevicePropertyDeviceIsAlive) { object in
            var alive: UInt32 = 1
            _ = HAL.read(object, kAudioDevicePropertyDeviceIsAlive, into: &alive)
            if alive == 0 { onSignal(.aggregateDied) }
        }
        listen(on: aggregateID, selector: kAudioAggregateDevicePropertyFullSubDeviceList) { _ in
            onSignal(.compositionChanged)
        }
        listen(on: aggregateID, selector: kAudioAggregateDevicePropertyTapList) { _ in
            onSignal(.compositionChanged)
        }
        listen(on: aggregateID, selector: kAudioDevicePropertyNominalSampleRate) { _ in
            onSignal(.sampleRateOrFormatChanged)
        }
        listen(on: tapID, selector: kAudioTapPropertyFormat) { _ in
            onSignal(.sampleRateOrFormatChanged)
        }
        // Deliberately NOT listening to kAudioDevicePropertyDeviceIsRunning —
        // header-documented to dispatch synchronously from the IO context.
    }

    private func listen(
        on object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        handler: @escaping @Sendable (AudioObjectID) -> Void
    ) {
        var address = HAL.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler(object)
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block)
        if status == noErr {
            listeners.append((object, address, block))
        } else {
            Self.log.error("listener \(selector, privacy: .public) on \(object) failed: \(status)")
        }
    }

    private func logStatus(_ status: OSStatus, _ what: StaticString) {
        if status != noErr {
            Self.log.error("\(what, privacy: .public) failed: \(status)")
        }
    }
}
