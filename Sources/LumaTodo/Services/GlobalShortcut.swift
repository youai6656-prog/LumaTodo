import AppKit
import Carbon
import Observation

@MainActor @Observable
final class GlobalShortcut {
    private(set) var error: OSStatus?
    @ObservationIgnored var onPress: (() -> Void)?
    @ObservationIgnored private var reference: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var active: Shortcut?
    @ObservationIgnored private var serial: UInt32 = 0
    private static let signature: OSType = 0x4C554D41

    func register(_ shortcut: Shortcut?) {
        guard let shortcut else {
            if let reference { UnregisterEventHotKey(reference) }
            serial &+= 1
            reference = nil
            active = nil
            error = nil
            return
        }
        if shortcut == active {
            error = nil
            return
        }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                guard let event, let data else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                let owner = Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue()
                let signature = id.signature
                let serial = id.id
                Task { @MainActor in
                    if signature == GlobalShortcut.signature, serial == owner.serial { owner.onPress?() }
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else {
                error = status
                return
            }
        }

        var candidate: EventHotKeyRef?
        let nextSerial = serial &+ 1
        let id = EventHotKeyID(signature: Self.signature, id: nextSerial)
        let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else {
            error = status == noErr ? OSStatus(eventNotHandledErr) : status
            return
        }
        if let reference { UnregisterEventHotKey(reference) }
        reference = candidate
        active = shortcut
        serial = nextSerial
        error = nil
    }

    func change(to shortcut: Shortcut) -> Bool {
        register(shortcut)
        return error == nil
    }
}

extension Shortcut {
    var display: String {
        let flags: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return flags.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + label
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
              let characters = event.charactersIgnoringModifiers,
              let label = Self.keyName(characters: characters, code: event.keyCode) else { return nil }
        key = UInt32(event.keyCode)
        modifiers = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.label = label
    }

    private static func keyName(characters: String, code: UInt16) -> String? {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Escape: return nil
        default:
            if let scalar = characters.unicodeScalars.first,
               (UInt32(NSF1FunctionKey)...UInt32(NSF20FunctionKey)).contains(scalar.value) {
                return "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)"
            }
            guard characters.count == 1, characters.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse
            }) else { return nil }
            return characters.uppercased()
        }
    }
}
