import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    nonisolated static let defaultKeyCode = UInt32(kVK_Space)
    nonisolated static let defaultModifiers = UInt32(controlKey | optionKey)

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed = false
    private let signature: OSType = 0x41445250 // ADRP
    private var identifier: UInt32 = 0
    private static var nextIdentifier: UInt32 = 1
    private var binding: (keyCode: UInt32, modifiers: UInt32)?

    init(keyCode: UInt32 = GlobalHotKey.defaultKeyCode, modifiers: UInt32 = GlobalHotKey.defaultModifiers) throws {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var eventID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &eventID) == noErr,
                  eventID.signature == 0x41445250 else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            let receivedIdentifier = eventID.id
            let instance = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            guard receivedIdentifier == instance.identifier else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor [weak instance] in instance?.handle(kind, identifier: receivedIdentifier) }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotKeyError(status: status) }
        do { try register(keyCode: keyCode, modifiers: modifiers) }
        catch { if let handler { RemoveEventHandler(handler); self.handler = nil }; throw error }
    }

    func register(keyCode: UInt32, modifiers: UInt32) throws {
        if let binding, binding.keyCode == keyCode, binding.modifiers == modifiers { return }
        var replacement: EventHotKeyRef?
        let newIdentifier = Self.nextIdentifier
        Self.nextIdentifier &+= 1
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: signature, id: newIdentifier), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { throw HotKeyError(status: status) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        identifier = newIdentifier
        binding = (keyCode, modifiers)
        if pressed { pressed = false; onRelease?() }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        binding = nil
        if pressed { pressed = false; onRelease?() }
    }

    private func handle(_ kind: UInt32, identifier: UInt32) {
        guard hotKey != nil, identifier == self.identifier else { return }
        if kind == UInt32(kEventHotKeyPressed), !pressed { pressed = true; onPress?() }
        else if kind == UInt32(kEventHotKeyReleased), pressed { pressed = false; onRelease?() }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    struct HotKeyError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not register the global shortcut (error \(status)). It may already be in use." }
    }
}
