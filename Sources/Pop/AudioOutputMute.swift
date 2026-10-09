import CoreAudio

/// Mutes the DEFAULT system audio output while the mic is open, then restores the
/// user's prior state EXACTLY.
///
/// WHY CoreAudio directly: `AVAudioSession` (the easy mute API) does not exist on
/// macOS, and the default output device's `kAudioDevicePropertyMute` is the only
/// way to silence the speakers without changing volume.
///
/// Scope: only the DEFAULT output device is muted. Muting side devices (a USB
/// interface, an aggregate) is deliberately out of scope — the request is "mute
/// the speakers", and touching non-default devices risks altering audio the user
/// did not intend to change.
///
/// INVARIANT: this is a BORROW, not a state change. If the device was ALREADY
/// muted by the user, we do nothing and remember nothing, so `restore()` can
/// never force-unmute a device the user had muted themselves.
@MainActor
enum AudioOutputMute {
    private static var mutedDevice = AudioDeviceID(kAudioObjectUnknown)
    private static var priorMuted: Bool?

    /// Returns whether WE muted (false if it was already muted or anything
    /// failed — in which case there is nothing to restore).
    @discardableResult
    static func mute() -> Bool {
        guard let device = defaultOutputDevice() else {
            log("VOICE_MUTE outcome=no-default-device")
            return false
        }
        var current: UInt32 = 0
        guard readMute(device: device, value: &current) else {
            log("VOICE_MUTE outcome=read-failed")
            return false
        }
        guard current == 0 else {
            log("VOICE_MUTE outcome=already-muted")
            return false
        }
        guard setMute(device: device, value: 1) else {
            log("VOICE_MUTE outcome=set-failed")
            return false
        }
        mutedDevice = device
        priorMuted = false
        log("VOICE_MUTE outcome=muted")
        return true
    }

    /// Restores the pre-listen state. No-op when we never muted.
    static func restore() {
        guard let prior = priorMuted else { return }
        _ = setMute(device: mutedDevice, value: prior ? 1 : 0)
        log("VOICE_UNMUTE outcome=\(prior ? "remuted" : "unmuted")")
        mutedDevice = AudioDeviceID(kAudioObjectUnknown)
        priorMuted = nil
    }

    private static func log(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readMute(device: AudioDeviceID, value: inout UInt32) -> Bool {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    }

    private static func setMute(device: AudioDeviceID, value: UInt32) -> Bool {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var v = value
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v
        ) == noErr
    }
}
