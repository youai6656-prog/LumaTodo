import SwiftUI

// The AppKit field editor owns marked text and standard editing/undo commands.
struct NativeTaskField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    var focusRequest: Int = 0
    var focused: ((Bool) -> Void)?
    var submit: () -> Void
    var escape: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 13)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        let editor = field.currentEditor() as? NSTextView
        if let editor {
            // The cell can still hold its pre-edit string while the field editor is active.
            if !editor.hasMarkedText(), editor.string != text {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }
        if focusRequest != 0, coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeKey()
                window.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTaskField
        var lastFocusRequest = 0

        init(parent: NativeTaskField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused?(true) }

        func controlTextDidEndEditing(_ notification: Notification) { parent.focused?(false) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else { return }
            parent.text = editor.string
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // A candidate confirmation may clear marked text before AppKit calls the delegate.
            let wasComposing = (control.window as? TaskPanel)?.keyBeganWithMarkedText == true
            if wasComposing || textView.hasMarkedText() {
                return commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.cancelOperation(_:))
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                parent.submit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let escape = parent.escape {
                escape()
                return true
            }
            return false
        }
    }
}
