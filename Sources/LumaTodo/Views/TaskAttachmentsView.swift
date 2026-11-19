import Observation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class TaskAttachmentDraft {
    enum Item: Identifiable {
        case saved(AttachmentInfo)
        case staged(StagedAttachment)

        var info: AttachmentInfo {
            switch self {
            case .saved(let info): info
            case .staged(let attachment): attachment.info
            }
        }

        var id: UUID { info.id }
        var type: UTType? { UTType(info.contentType) }
    }

    struct ImportIssue: Identifiable {
        let id = UUID()
        let text: String
    }

    private let manager: AttachmentManager
    private let saved: [AttachmentInfo]
    private var staged: [StagedAttachment] = []
    private var removed: Set<UUID> = []
    private(set) var importing = false
    private(set) var issues: [ImportIssue] = []
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(manager: AttachmentManager, saved: [AttachmentInfo]) {
        self.manager = manager
        self.saved = saved
    }

    var items: [Item] {
        saved.compactMap { removed.contains($0.id) ? nil : .saved($0) } + staged.map(Item.staged)
    }

    var changes: AttachmentChanges { AttachmentChanges(adding: staged, removing: removed) }
    var isDirty: Bool { !staged.isEmpty || !removed.isEmpty || importing }

    func addFiles(_ urls: [URL], words: Words) {
        guard !urls.isEmpty else { return }
        if !beginImport(words) { return }
        let manager = manager
        importTask = Task { [weak self] in
            let result = await manager.importFiles(urls)
            guard let self, !Task.isCancelled else {
                manager.discard(result.imported)
                return
            }
            finishImport(result.imported, issues: result.failures.map {
                ImportIssue(text: "\($0.name) · \($0.error.message(words))")
            })
        }
    }

    func addDrop(_ providers: [NSItemProvider], words: Words) -> Bool {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }),
              beginImport(words) else { return false }
        let manager = manager
        importTask = Task { [weak self] in
            let files = await AttachmentDrop.load(providers)
            guard let self, !Task.isCancelled else { return }
            guard !files.isEmpty else {
                finishImport([], issues: [ImportIssue(text: words("无法读取拖入的文件。", "The dropped files could not be read."))])
                return
            }
            let result = await manager.importFiles(files)
            guard !Task.isCancelled else {
                manager.discard(result.imported)
                return
            }
            finishImport(result.imported, issues: result.failures.map {
                ImportIssue(text: "\($0.name) · \($0.error.message(words))")
            })
        }
        return true
    }

    func addImage(_ data: Data, type: UTType, words: Words) {
        guard beginImport(words) else { return }
        let manager = manager
        let name = words("剪贴板图片", "Clipboard image") + "." + (type.preferredFilenameExtension ?? "image")
        importTask = Task { [weak self] in
            do {
                let result = try await manager.importImage(data, name: name, contentType: type)
                guard let self, !Task.isCancelled else {
                    manager.discard([result])
                    return
                }
                finishImport([result], issues: [])
            } catch {
                guard let self, !Task.isCancelled else { return }
                finishImport([], issues: [ImportIssue(text: Self.message(for: error, words: words))])
            }
        }
    }

    func remove(_ item: Item) {
        switch item {
        case .saved(let info):
            removed.insert(info.id)
        case .staged(let attachment):
            staged.removeAll { $0.info.id == attachment.info.id }
            manager.discard([attachment])
        }
    }

    func url(for item: Item) throws -> URL {
        switch item {
        case .saved(let info): try manager.url(for: info)
        case .staged(let attachment): try manager.url(for: attachment)
        }
    }

    func markSaved() {
        staged.removeAll()
        removed.removeAll()
    }

    func discard() {
        importTask?.cancel()
        importTask = nil
        importing = false
        manager.discard(staged)
        staged.removeAll()
        removed.removeAll()
    }

    func presentIssue(_ error: Error, words: Words) {
        issues = [ImportIssue(text: Self.message(for: error, words: words))]
    }

    func clearIssues() { issues.removeAll() }

    private func beginImport(_ words: Words) -> Bool {
        guard !importing else {
            issues = [ImportIssue(text: words("等当前附件导入完成后再添加。", "Wait for the current import before adding more files."))]
            return false
        }
        importing = true
        clearIssues()
        return true
    }

    private func finishImport(_ items: [StagedAttachment], issues: [ImportIssue]) {
        staged.append(contentsOf: items)
        self.issues = issues
        importing = false
        importTask = nil
    }

    private static func message(for error: Error, words: Words) -> String {
        if let attachmentError = error as? AttachmentError { return attachmentError.message(words) }
        if let previewError = error as? FilePreviewService.PreviewError { return previewError.message(words) }
        return error.localizedDescription
    }
}

struct TaskAttachmentsView: View {
    @Binding var notes: String
    let attachments: TaskAttachmentDraft
    let words: Words
    let onCancel: () -> Void
    let onSave: () -> Void
    @State private var pickingFiles = false
    @State private var dropTargeted = false
    @State private var textDropTargeted = false
    @State private var notesFocused = false
    @State private var previewURL: URL?
    @State private var previewRequest: Task<Void, Never>?
    private var appearance = PanelAppearance()

    init(notes: Binding<String>, attachments: TaskAttachmentDraft, words: Words,
         onCancel: @escaping () -> Void, onSave: @escaping () -> Void) {
        _notes = notes
        self.attachments = attachments
        self.words = words
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        let items = attachments.items
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(words("任务描述", "Description"))
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !items.isEmpty {
                    let count = items.count
                    Text(words("\(count) 个附件", "\(count) attachment\(count == 1 ? "" : "s")"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(appearance.secondary)
                }
                Button {
                    pickingFiles = true
                } label: {
                    Label(words("添加附件", "Add attachments"), systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 24)
                        .contentShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.borderless)
                .disabled(attachments.importing)
                .help(words("添加附件 · 单个文件最多 50 MB", "Add attachments · 50 MB per file"))
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)

            ZStack(alignment: .topLeading) {
                NativeDescriptionField(label: words("任务描述", "Task description"), text: $notes,
                    onFiles: { attachments.addFiles($0, words: words) },
                    onImage: { attachments.addImage($0, type: $1, words: words) },
                    onDropHighlight: { textDropTargeted = $0 },
                    onFocus: { notesFocused = $0 },
                    onCancel: onCancel, onSave: onSave
                )
                if notes.isEmpty && !notesFocused {
                    Text(words("添加说明，或拖入文件", "Add notes or drop files here"))
                        .font(.system(size: 13))
                        .foregroundStyle(appearance.secondary)
                        .padding(.leading, 6).padding(.top, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 62)
            .padding(.horizontal, 8)

            if !items.isEmpty {
                Divider().padding(.horizontal, 9)
                LazyVStack(spacing: 3) {
                    ForEach(items) { item in
                        let thumbnailURL = item.type?.conforms(to: .image) == true ? try? attachments.url(for: item) : nil
                        AttachmentItemRow(item: item, url: thumbnailURL, words: words,
                                          preview: { preview(item) }, open: { open(item) },
                                          reveal: { reveal(item) }, remove: { remove(item) })
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
            }

            if attachments.importing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(words("正在复制附件…", "Copying attachments…")).font(.caption)
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
        .padding(.bottom, 5)
        .background(Color.primary.opacity(appearance.dark ? 0.052 : 0.034), in: .rect(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).strokeBorder(
                dropTargeted || textDropTargeted || notesFocused ? appearance.accent.opacity(0.8) : appearance.line,
                lineWidth: dropTargeted || textDropTargeted ? 1.5 : 0.75
            )
            .allowsHitTesting(false)
        }
        .background {
            if dropTargeted || textDropTargeted {
                RoundedRectangle(cornerRadius: 11).fill(appearance.accent.opacity(0.10))
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { attachments.addDrop($0, words: words) }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files): attachments.addFiles(files, words: words)
            case .failure(let error):
                let cocoa = error as NSError
                if cocoa.domain != NSCocoaErrorDomain || cocoa.code != CocoaError.userCancelled.rawValue {
                    attachments.presentIssue(error, words: words)
                }
            }
        }
        .quickLookPreview($previewURL)
        .onDisappear { previewRequest?.cancel() }
        .overlay(alignment: .topTrailing) {
            if dropTargeted || textDropTargeted {
                Text(words("松开以导入", "Drop to import"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .foregroundStyle(appearance.accent)
                    .background(.thickMaterial, in: .capsule)
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func preview(_ item: TaskAttachmentDraft.Item) {
        previewRequest?.cancel()
        previewRequest = Task { @MainActor in
            do {
                let url = try attachments.url(for: item)
                try await FilePreviewService.checkPreview(url, type: item.type)
                guard !Task.isCancelled, attachments.items.contains(where: { $0.id == item.id }) else { return }
                previewURL = url
            } catch {
                if !Task.isCancelled { attachments.presentIssue(error, words: words) }
            }
        }
    }

    private func open(_ item: TaskAttachmentDraft.Item) {
        Task { @MainActor in
            do { try await FilePreviewService.open(attachments.url(for: item), type: item.type) }
            catch { attachments.presentIssue(error, words: words) }
        }
    }

    private func reveal(_ item: TaskAttachmentDraft.Item) {
        do { try FilePreviewService.reveal(attachments.url(for: item)) }
        catch { attachments.presentIssue(error, words: words) }
    }

    private func remove(_ item: TaskAttachmentDraft.Item) {
        if previewURL == (try? attachments.url(for: item)) { previewURL = nil }
        attachments.remove(item)
    }
}

private struct AttachmentItemRow: View {
    let item: TaskAttachmentDraft.Item
    let url: URL?
    let words: Words
    var preview: () -> Void
    var open: () -> Void
    var reveal: () -> Void
    var remove: () -> Void
    @State private var thumbnail: CGImage?
    @State private var hovering = false
    @Environment(\.displayScale) private var scale
    private var appearance = PanelAppearance()

    init(item: TaskAttachmentDraft.Item, url: URL?, words: Words, preview: @escaping () -> Void,
         open: @escaping () -> Void, reveal: @escaping () -> Void, remove: @escaping () -> Void) {
        self.item = item
        self.url = url
        self.words = words
        self.preview = preview
        self.open = open
        self.reveal = reveal
        self.remove = remove
    }

    var body: some View {
        HStack(spacing: 5) {
            Button(action: preview) {
                HStack(spacing: 7) {
                    icon
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.info.originalFileName)
                            .font(.system(size: 12, weight: .medium))
                            .truncationMode(.middle)
                            .lineLimit(1)
                        Text(item.info.fileSize.formatted(.byteCount(style: .file).locale(words.locale)))
                            .font(.system(size: 10))
                            .foregroundStyle(appearance.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(item.info.originalFileName)
            .accessibilityHint(words("使用快速查看预览", "Preview in Quick Look"))

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 15)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(words("附件操作", "Attachment actions"))

            Button(action: remove) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(appearance.secondary)
                    .frame(width: 21, height: 23)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(words("从任务中移除附件", "Remove attachment from task"))
            .accessibilityLabel(words("移除 \(item.info.originalFileName)", "Remove \(item.info.originalFileName)"))
        }
        .padding(.horizontal, 5)
        .frame(minHeight: 35)
        .background(Color.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 6))
        .onHover { hovering = $0 }
        .task(id: url) {
            thumbnail = nil
            guard item.type?.conforms(to: .image) == true, let url else { return }
            let image = await FilePreviewService.thumbnail(url, pixels: min(96, Int(28 * scale)))
            if !Task.isCancelled { thumbnail = image }
        }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var icon: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: scale)
                .resizable().scaledToFit()
                .clipShape(.rect(cornerRadius: 4))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(for: item.type ?? .data))
                .resizable().scaledToFit()
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(words("预览", "Preview"), action: preview)
        Button(words("在默认应用中打开", "Open in Default App"), action: open)
        Button(words("在 Finder 中显示", "Show in Finder"), action: reveal)
        Divider()
        Button(words("移除附件", "Remove Attachment"), role: .destructive, action: remove)
    }
}
