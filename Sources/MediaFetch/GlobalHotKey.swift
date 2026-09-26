import AppKit
import Carbon.HIToolbox

/// System-wide ⌘⇧D via Carbon's RegisterEventHotKey: no Accessibility
/// permission needed, and the clipboard is read only when the key is pressed.
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let preferenceKey = "MediaFetch.hotkey.enabled"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.shared.onTrigger?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x534F4F47), id: 1) // 'SOOG'
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
