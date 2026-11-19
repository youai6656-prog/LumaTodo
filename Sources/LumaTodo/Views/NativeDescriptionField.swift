import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AttachmentDrop {
    private static let imageTypes: [(NSPasteboard.PasteboardType, UTType)] = [
        (.png, .png),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpeg),
        (NSPasteboard.PasteboardType(UTType.heic.identifier), .heic),
        (.tiff, .tiff)
    ]

    static var pasteTypes: [NSPasteboard.PasteboardType] { [.fileURL] + imageTypes.map(\.0) }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.filter(\.isFileURL) ?? []
    }

    static func image(from pasteboard: NSPasteboard, matching type: NSPasteboard.PasteboardType? = nil) -> (Data, UTType)? {
        for (pasteType, contentType) in imageTypes where type == nil || type == pasteType {
            if let data = pasteboard.data(forType: pasteType) { return (data, contentType) }
        }
        return nil
    }

    static func load(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadURL(provider) { urls.append(url) }
        }
        return urls
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { object, _ in
                let url: URL?
                switch object {
                case let object as URL: url = object
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                case let string as String: url = URL(string: string)
                default: url = nil
                }
                continuation.resume(returning: url.flatMap { $0.isFileURL ? $0 : nil })
            }
        }
    }
}

struct NativeDescriptionField: NSViewRepresentable {
    let label: String
    @Binding var text: String
    var onFiles: ([URL]) -> Void
    var onImage: (Data, UTType) -> Void
    var onDropHighlight: (Bool) -> Void
    var onFocus: (Bool) -> Void
    var onCancel: () -> Void
    var onSave: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = DescriptionTextView(frame: scroll.bounds)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 13)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 1, height: 4)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        if !view.registeredDraggedTypes.contains(.fileURL) {
            view.registerForDraggedTypes(view.registeredDraggedTypes + [.fileURL])
        }
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? DescriptionTextView else { return }
        context.coordinator.parent = self
        view.setAccessibilityLabel(label)
        view.onFiles = onFiles
        view.onImage = onImage
        view.onDropHighlight = onDropHighlight
        view.onCancel = onCancel
        view.onSave = onSave
        if !view.hasMarkedText(), view.string != text { view.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeDescriptionField

        init(parent: NativeDescriptionField) { self.parent = parent }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocus(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocus(false) }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            parent.text = view.string
        }
    }
}

final class DescriptionTextView: NSTextView {
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data, UTType) -> Void)?
    var onDropHighlight: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, [36, 76].contains(event.keyCode), !TaskPanel.hasActiveComposition {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let types = AttachmentDrop.pasteTypes
        return types + super.readablePasteboardTypes.filter { !types.contains($0) }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)), isEditable,
           NSPasteboard.general.availableType(from: AttachmentDrop.pasteTypes) != nil { return true }
        return super.validateMenuItem(menuItem)
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .fileURL, let onFiles {
            let files = AttachmentDrop.urls(from: pasteboard)
            if !files.isEmpty {
                onFiles(files)
                return true
            }
        }
        if let onImage, let (data, contentType) = AttachmentDrop.image(from: pasteboard, matching: type) {
            onImage(data, contentType)
            return true
        }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func cancelOperation(_ sender: Any?) {
        guard !TaskPanel.hasActiveComposition else {
            super.cancelOperation(sender)
            return
        }
        onCancel?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.fileURL) == true else { return super.draggingEntered(sender) }
        onDropHighlight?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.fileURL) == true else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDropHighlight?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDropHighlight?(false)
        let files = AttachmentDrop.urls(from: sender.draggingPasteboard)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        onFiles?(files)
        return true
    }
}
