import AppKit
import CoreAudio
import Foundation

/// Thin, typed wrappers over the C HAL property API. The Swift overlay
/// (`AudioHardwareSystem` et al.) is deliberately not used — its failure
/// semantics are unverified, and every battle-tested reference implementation
/// speaks the C API with explicit `OSStatus` handling.
enum HAL {

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size POD property.
    static func read<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        into value: inout T
    ) -> OSStatus {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
    }

    /// Reads a variable-length array property.
    static func readArray<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type
    ) throws(HALError) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard status == noErr else { throw HALError(selector: selector, status: status) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw HALError(selector: selector, status: status) }
        // The property may have shrunk between the size query and the read —
        // drop uninitialized trailing elements.
        let returned = Int(size) / MemoryLayout<T>.stride
        if returned < values.count {
            values.removeLast(values.count - returned)
        }
        return values
    }

    /// Reads a CFString property.
    static func readString(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Translates a POSIX PID to its HAL process object. Returns `nil` when
    /// the PID has no Core Audio client (per header: `noErr` + unknown ID).
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    /// The current default input device, or `nil` if none exists.
    static func defaultInputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = read(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice, into: &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// A device's persistent UID.
    static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        readString(deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// Ordered input-scope stream objects of a device.
    static func inputStreams(_ deviceID: AudioObjectID) throws(HALError) -> [AudioObjectID] {
        try readArray(
            deviceID, kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self)
    }

    /// A stream's virtual format — what an IOProc actually delivers.
    static func streamVirtualFormat(_ streamID: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        let status = read(streamID, kAudioStreamPropertyVirtualFormat, into: &asbd)
        return status == noErr ? asbd : nil
    }

    /// A device's nominal sample rate — for an aggregate, the rate every
    /// input stream actually delivers at (drift compensation resamples
    /// sub-streams onto the aggregate clock).
    static func nominalSampleRate(_ deviceID: AudioObjectID) -> Double? {
        var rate: Float64 = 0
        let status = read(deviceID, kAudioDevicePropertyNominalSampleRate, into: &rate)
        return status == noErr && rate > 0 ? rate : nil
    }
}

/// A HAL property read failure.
struct HALError: Error {
    let selector: AudioObjectPropertySelector
    let status: OSStatus
}

/// Snapshot discovery of processes the HAL knows about — for pickers and the
/// Phase-2 harness.
public enum AudioProcessDirectory {

    public struct Entry: Sendable, Identifiable {
        /// The HAL process object.
        public let id: AudioObjectID
        public let pid: pid_t
        public let bundleID: String?
        /// Whether the process is currently emitting audio ('piro').
        public let isRunningOutput: Bool
    }

    /// All current HAL client processes.
    public static func snapshot() throws -> [Entry] {
        let objects = try HAL.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        return objects.compactMap { objectID in
            var pid: pid_t = -1
            guard HAL.read(objectID, kAudioProcessPropertyPID, into: &pid) == noErr else {
                return nil
            }
            var running: UInt32 = 0
            _ = HAL.read(objectID, kAudioProcessPropertyIsRunningOutput, into: &running)
            return Entry(
                id: objectID,
                pid: pid,
                bundleID: HAL.readString(objectID, kAudioProcessPropertyBundleID),
                isRunningOutput: running != 0)
        }
    }

    /// One pickable app, aggregating every HAL client process that belongs to
    /// it (the app process itself and/or its helpers).
    public struct AppEntry: Sendable, Identifiable {
        /// The app's own PID — the value to put in `CaptureTarget.process`.
        public let id: pid_t
        public let name: String
        /// True if any of the app's processes is currently emitting audio.
        public let isPlayingAudio: Bool
    }

    /// App-level view of ``snapshot()``: every HAL client process is
    /// attributed to its nearest ancestor that is a regular app (browsers and
    /// conferencing apps emit audio from helper processes — the user must see
    /// "Chrome", not "Chrome Helper (Renderer)"). HAL clients with no app
    /// ancestor (daemons) appear under their own BSD name.
    @MainActor
    public static func appLevelSnapshot(excluding excludedPID: pid_t) throws -> [AppEntry] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
        var aggregated: [pid_t: (name: String, playing: Bool)] = [:]

        for entry in try snapshot() where entry.pid != excludedPID {
            let owner = apps.first { app in
                ProcessTree.isDescendant(entry.pid, of: app.processIdentifier)
            }
            let key = owner?.processIdentifier ?? entry.pid
            guard key != excludedPID else { continue }
            let name = owner?.localizedName
                ?? ProcessTree.name(of: entry.pid)
                ?? entry.bundleID
                ?? "pid \(entry.pid)"
            let existing = aggregated[key]
            aggregated[key] = (
                name: existing?.name ?? name,
                playing: (existing?.playing ?? false) || entry.isRunningOutput)
        }
        return aggregated
            .map { AppEntry(id: $0.key, name: $0.value.name, isPlayingAudio: $0.value.playing) }
            .sorted { ($0.isPlayingAudio ? 0 : 1, $0.name) < ($1.isPlayingAudio ? 0 : 1, $1.name) }
    }
}
