import AppKit
import Carbon.HIToolbox

/// Carbon global hot key (Option+Space) used to summon/dismiss the panel from
/// any application. A failure here is non-fatal: the orb still works.
@MainActor
final class HotkeyCenter {
    /// 'POP1'
    nonisolated static let signature: OSType = 0x504F_5031
    private static let eventHotKeyIDValue: UInt32 = 1
    private static let spaceKeyCode: UInt32 = 0x31          // kVK_Space
    private static let optionMask: UInt32 = 0x0800          // optionKey

    private let onToggle: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    func register() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            popHotkeyEventHandler,
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        guard installStatus == noErr else {
            print("HOTKEY_ERROR \(installStatus)")
            fflush(stdout)
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.eventHotKeyIDValue
        )
        let status = RegisterEventHotKey(
            Self.spaceKeyCode,
            Self.optionMask,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            print("HOTKEY_REGISTERED option+space")
        } else {
            print("HOTKEY_ERROR \(status)")
        }
        fflush(stdout)
    }

    /// Carbon dispatches hot key events on the main thread during event
    /// handling, so the main-actor hop below never actually defers.
    fileprivate nonisolated func fire() {
        MainActor.assumeIsolated {
            onToggle()
        }
    }
}

/// Non-capturing C callback: the owning `HotkeyCenter` arrives via `userData`.
private let popHotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else {
        return OSStatus(eventNotHandledErr)
    }

    Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().fire()
    return OSStatus(noErr)
}