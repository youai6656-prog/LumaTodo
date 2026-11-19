import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LumaTodo

struct AttachmentTests {
    @Test func importsPDFImageAndCodeAsManagedCopies() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = AttachmentManager(databaseURL: directory.appending(path: "Tasks.store"))
        let contents = [("作业.pdf", Data("%PDF-1.4\n%%EOF".utf8)),
                        ("作业截图.png", onePixelPNG),
                        ("ExceptionDemo.java", Data("class ExceptionDemo {}".utf8))]
        let sources = try contents.map { name, bytes in
            let url = directory.appending(path: name)
            try bytes.write(to: url)
            return url
        }
        let batch = await manager.importFiles(sources)
        #expect(batch.failures.isEmpty)
        #expect(batch.imported.map(\.info.originalFileName) == contents.map(\.0))
        #expect(batch.imported.map(\.info.contentType).prefix(2) == [UTType.pdf.identifier, UTType.png.identifier][...])

        try manager.promote(batch.imported)
        for url in sources { try FileManager.default.removeItem(at: url) }
        for (item, source) in zip(batch.imported, contents) {
            let managed = try manager.url(for: item.info)
            #expect(try Data(contentsOf: managed) == source.1)
            #expect(item.info.fileSize == source.1.count)
            #expect(!FileManager.default.isExecutableFile(atPath: managed.path))
        }
    }

    @Test func pastedImageCanBeDiscardedAndCorruptDataReturnsAnError() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = AttachmentManager(databaseURL: directory.appending(path: "Tasks.store"))
        let image = try await manager.importImage(onePixelPNG, name: "Clipboard", contentType: .png)
        let stagedURL = try manager.url(for: image)
        #expect(image.info.originalFileName == "Clipboard.png")
        #expect(try Data(contentsOf: stagedURL) == onePixelPNG)
        manager.discard([image])
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        await #expect(throws: AttachmentError.invalidFile) {
            try await manager.importImage(Data("not an image".utf8), name: "Clipboard", contentType: .png)
        }
    }

    @Test func oversizedMissingAndSymlinkFilesAreRejectedWithoutLosingValidSiblings() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = AttachmentManager(databaseURL: directory.appending(path: "Tasks.store"))
        let valid = directory.appending(path: "example.swift")
        try Data("print(1)".utf8).write(to: valid)
        let large = directory.appending(path: "large.zip")
        try Data().write(to: large)
        let writer = try FileHandle(forWritingTo: large)
        try writer.truncate(atOffset: UInt64(FileStorageService.maximumFileSize) + 1)
        try writer.close()
        let link = directory.appending(path: "link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        let missing = directory.appending(path: "missing.pdf")
        let sandboxed = directory.appending(path: "private.txt")
        try Data("private".utf8).write(to: sandboxed)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sandboxed.path)
        let sources = getuid() == 0 ? [large, link, missing, valid] : [large, link, missing, sandboxed, valid]
        let expected: [AttachmentError] = getuid() == 0 ? [.tooLarge, .invalidFile, .sourceMissing]
            : [.tooLarge, .invalidFile, .sourceMissing, .permissionDenied]
        let batch = await manager.importFiles(sources)
        #expect(batch.failures.map(\.error) == expected)
        #expect(batch.imported.count == 1)
        #expect(batch.imported.first?.info.originalFileName == valid.lastPathComponent)
        manager.discard(batch.imported)
    }

    @MainActor @Test func sameNamesAndCancellationDoNotRemoveAnotherTaskFiles() throws {
        try withStore { store in
            let databaseURL = try #require(store.container.configurations.first?.url)
            let directory = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appending(path: "notes.md")
            let storage = FileStorageService(databaseURL: databaseURL)
            let manager = store.attachmentManager

            try Data("first".utf8).write(to: source)
            let first = try storage.stage(file: source)
            let original = try store.save(TaskDraft(title: "First"), attachments: .init(adding: [first]))
            let originalInfo = try #require(store.attachments(for: original.id).first)
            let originalURL = try manager.url(for: originalInfo)

            try Data("second".utf8).write(to: source)
            let second = try storage.stage(file: source)
            let other = try store.save(TaskDraft(title: "Second"), attachments: .init(adding: [second]))
            let otherInfo = try #require(store.attachments(for: other.id).first)
            let otherURL = try manager.url(for: otherInfo)
            #expect(originalInfo.originalFileName == otherInfo.originalFileName)
            #expect(originalInfo.relativePath != otherInfo.relativePath)
            #expect(try String(contentsOf: originalURL, encoding: .utf8) == "first")
            #expect(try String(contentsOf: otherURL, encoding: .utf8) == "second")

            let abandoned = try storage.stage(file: source)
            let abandonedURL = try manager.url(for: abandoned)
            let cancelled = AttachmentChanges(adding: [abandoned], removing: [originalInfo.id])
            manager.discard(cancelled.adding)
            #expect(!FileManager.default.fileExists(atPath: abandonedURL.path))
            #expect(store.attachments(for: original.id) == [originalInfo])
            #expect(FileManager.default.fileExists(atPath: originalURL.path))

            try store.save(TaskDraft(task: original), editing: original, attachments: .init(removing: [originalInfo.id]))
            #expect(store.attachments(for: original.id).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: originalURL.path))
            #expect(FileManager.default.fileExists(atPath: otherURL.path))
            try store.delete(other)
            #expect(!FileManager.default.fileExists(atPath: otherURL.path))
            #expect(try String(contentsOf: source, encoding: .utf8) == "second")
        }
    }

    @MainActor @Test func failedMultiFilePromotionRestoresStagingAndLeavesTaskUntouched() throws {
        try withStore { store in
            let databaseURL = try #require(store.container.configurations.first?.url)
            let directory = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appending(path: "notes.md")
            try Data("original bytes".utf8).write(to: source)
            let storage = FileStorageService(databaseURL: databaseURL)
            let manager = store.attachmentManager
            let uploaded = try storage.stage(file: source)
            let missing = try storage.stage(file: source)
            manager.discard([missing])
            let stagedURL = try manager.url(for: uploaded)

            let task = try store.save(TaskDraft(title: "Original title"))
            #expect(throws: AttachmentError.managedFileUnavailable) {
                try store.save(TaskDraft(title: "Changed title"), editing: task,
                               attachments: .init(adding: [uploaded, missing]))
            }
            #expect(task.title == "Original title")
            #expect(store.attachments(for: task.id).isEmpty)
            #expect(try manager.url(for: uploaded) == stagedURL)
            #expect(throws: AttachmentError.managedFileUnavailable) { try manager.url(for: uploaded.info) }
            manager.discard([uploaded])
        }
    }

    @MainActor @Test func recurringHistoryAndUndoPreserveSharedFileUntilFinalRemoval() throws {
        try withStore { store in
            let databaseURL = try #require(store.container.configurations.first?.url)
            let directory = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appending(path: "project.md")
            try Data("course materials".utf8).write(to: source)
            let storage = FileStorageService(databaseURL: databaseURL)
            let uploaded = try storage.stage(file: source)
            let now = instant("2026-11-19T08:00:00Z")
            var draft = TaskDraft(title: "Daily")
            draft.due = now
            draft.hasTime = true
            draft.rule = RepeatRule(kind: .daily)
            let task = try store.save(draft, attachments: .init(adding: [uploaded]), now: now, timeZone: utc)
            let info = try #require(store.attachments(for: task.id).first)
            let managed = try store.attachmentManager.url(for: info)

            let history = try store.complete(task, now: now)
            let recorded = try #require(store.attachments(for: history.id).first)
            #expect(recorded.id != info.id)
            #expect(recorded.relativePath == info.relativePath)
            try store.restore(history, now: now)
            #expect(FileManager.default.fileExists(atPath: managed.path))
            #expect(store.attachments(for: task.id) == [info])

            let retained = try store.complete(task, now: now)
            try store.delete(task)
            #expect(FileManager.default.fileExists(atPath: managed.path))
            try store.delete(retained)
            #expect(!FileManager.default.fileExists(atPath: managed.path))
        }
    }

    @Test func startupReconciliationKeepsOnlyReferencedManagedFolders() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = AttachmentManager(databaseURL: directory.appending(path: "Tasks.store"))
        let committed = try await manager.importImage(onePixelPNG, name: "Committable", contentType: .png)
        let orphan = try await manager.importImage(onePixelPNG, name: "Orphan", contentType: .png)
        let interrupted = try await manager.importImage(onePixelPNG, name: "Interrupted", contentType: .png)
        let interruptedURL = try manager.url(for: interrupted)
        try manager.promote([committed, orphan])
        let orphanURL = try manager.url(for: orphan.info)
        manager.reconcile(committed: [committed.info])
        #expect(try Data(contentsOf: manager.url(for: committed.info)) == onePixelPNG)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(!FileManager.default.fileExists(atPath: interruptedURL.path))
    }
}

private let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+tmV0AAAAASUVORK5CYII=")!

private func scratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "LumaTodoAttachmentTest-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
