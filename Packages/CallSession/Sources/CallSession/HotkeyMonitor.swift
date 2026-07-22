import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Registers the global hotkey via Carbon `RegisterEventHotKey` — the one
/// system-wide hotkey API that needs no Accessibility permission. The
/// handler fires on the main actor.
@MainActor
public final class HotkeyMonitor {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "HotkeyMonitor")

    /// A hotkey binding (Carbon key code + Carbon modifier mask).
    public struct Binding: Sendable, Equatable {
        public let keyCode: UInt32
        public let modifiers: UInt32
        public let display: String

        public init(keyCode: UInt32, modifiers: UInt32, display: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.display = display
        }

        /// The default binding: ⌥⌘R.
        public static let optionCommandR = Binding(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(optionKey | cmdKey),
            display: "⌥⌘R")

        /// Live Assist "answer the last thing": ⌥⌘A.
        public static let optionCommandA = Binding(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey | cmdKey),
            display: "⌥⌘A")

        /// Code Assist region capture: ⇧⌥⌘C.
        public static let shiftOptionCommandC = Binding(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(shiftKey | optionKey | cmdKey),
            display: "⇧⌥⌘C")
    }

    // nonisolated(unsafe): written once during main-actor register(), read in
    // deinit — no concurrent access is possible.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?
    private let onPress: @MainActor () -> Void
    /// Distinguishes multiple monitors: every registered hotkey event is
    /// delivered to every installed handler, so each handler must check
    /// the event's id and pass on the ones that are not its own.
    private nonisolated let hotKeyIDNumber: UInt32

    public private(set) var binding: Binding

    /// Registers immediately; deregisters on deinit. `id` must be unique
    /// per monitor within the app.
    public init(
        binding: Binding = .optionCommandR,
        id: UInt32 = 1,
        onPress: @escaping @MainActor () -> Void
    ) {
        self.binding = binding
        self.hotKeyIDNumber = id
        self.onPress = onPress
        register()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        // C callback: hop back to the main actor and invoke the handler.
        // Events for OTHER hotkeys pass through untouched.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var firedID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            guard firedID.id == monitor.hotKeyIDNumber else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in
                monitor.onPress()
            }
            return noErr
        }

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(), callback, 1, &eventType, selfPointer, &handlerRef)
        guard installStatus == noErr else {
            Self.log.error("InstallEventHandler failed: \(installStatus)")
            return
        }
        eventHandlerRef = handlerRef

        let hotKeyID = EventHotKeyID(signature: OSType(0x53_41_41_41 /* 'SAAA' */), id: hotKeyIDNumber)
        var keyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &keyRef)
        guard registerStatus == noErr else {
            Self.log.error("RegisterEventHotKey failed: \(registerStatus)")
            return
        }
        hotKeyRef = keyRef
        Self.log.info("global hotkey registered: \(self.binding.display, privacy: .public)")
    }
}
