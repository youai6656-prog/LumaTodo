import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FileStorageService: Sendable {
    static let maximumFileSize: Int64 = 50_000_000
    private static let chunkSize = 1_048_576

    private let root: URL
    private var managed: URL { root.appending(path: "Files", directoryHint: .isDirectory) }
    private var staging: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }

    init(databaseURL: URL) {
        root = databaseURL.deletingLastPathComponent().appending(path: "Attachments", directoryHint: .isDirectory)
    }

    func stage(file source: URL) throws -> StagedAttachment {
        try Task.checkCancellation()
        guard source.isFileURL else { throw AttachmentError.invalidFile }
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }

        // Read a fixed descriptor and reject symlinks and special files before creating the managed copy.
        let descriptor = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw openError(errno) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw openError(errno) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw AttachmentError.invalidFile }
        guard status.st_size <= Self.maximumFileSize else { throw AttachmentError.tooLarge }

        let name = source.lastPathComponent
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: source.pathExtension) ?? .data
        return try stageContent(name: name, type: type) { output in
            var count: Int64 = 0
            while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                count += Int64(chunk.count)
                guard count <= Self.maximumFileSize else { throw AttachmentError.tooLarge }
                try output.write(contentsOf: chunk)
            }
            return count
        }
    }

    func stage(image data: Data, name: String, type: UTType) throws -> StagedAttachment {
        guard type.conforms(to: .image), !data.isEmpty else { throw AttachmentError.invalidFile }
        guard data.count <= Self.maximumFileSize else { throw AttachmentError.tooLarge }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0,
              CGImageSourceGetStatus(image) == .statusComplete else { throw AttachmentError.invalidFile }
        let resolvedName = URL(fileURLWithPath: name).pathExtension.isEmpty
            ? name + "." + (type.preferredFilenameExtension ?? "image") : name
        return try stageContent(name: resolvedName, type: type) { output in
            try output.write(contentsOf: data)
            return Int64(data.count)
        }
    }

    func fileURL(for info: AttachmentInfo, isStaged: Bool) throws -> URL {
        do {
            let folder = try folderURL(for: info, isStaged: isStaged)
            let file = folder.appending(path: info.storedFileName, directoryHint: .notDirectory)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isReadableKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.isReadable == true else {
                throw AttachmentError.managedFileUnavailable
            }
            return file
        } catch let error as AttachmentError {
            throw error
        } catch {
            throw AttachmentError.managedFileUnavailable
        }
    }

    func promote(_ items: [StagedAttachment]) throws {
        if items.isEmpty { return }
        let fm = FileManager.default
        var moved: [StagedAttachment] = []
        do {
            try createRootAndDirectory(managed)
            for item in items {
                _ = try fileURL(for: item.info, isStaged: true)
                let from = try folderURL(for: item.info, isStaged: true)
                let to = try folderURL(for: item.info, isStaged: false)
                try fm.moveItem(at: from, to: to)
                moved.append(item)
            }
        } catch {
            restoreStaging(moved)
            throw AttachmentError.fileOperation(error)
        }
    }

    func restoreStaging(_ items: [StagedAttachment]) {
        for item in items {
            do {
                let from = try folderURL(for: item.info, isStaged: false)
                let to = try folderURL(for: item.info, isStaged: true)
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                // Startup reconciliation can remove any unreferenced copy left by a failed rollback.
                NSLog("LumaTodo attachment rollback: %@", error.localizedDescription)
            }
        }
    }

    func discard(_ items: [StagedAttachment]) {
        for item in items { removeFolder(for: item.info, isStaged: true) }
    }

    func removeManaged(_ info: AttachmentInfo) {
        removeFolder(for: info, isStaged: false)
    }

    func reconcile(committed: [AttachmentInfo]) {
        // The product has one running app instance. Anything staged at startup belongs to an interrupted edit.
        clean(staging, keeping: [])
        let validFolders = committed.compactMap { folderName(for: $0) }
        guard validFolders.count == committed.count else {
            NSLog("LumaTodo skipped attachment orphan cleanup because an attachment path was invalid.")
            return
        }
        clean(managed, keeping: Set(validFolders))
    }

    private func stageContent(name: String, type: UTType, write: (FileHandle) throws -> Int64) throws -> StagedAttachment {
        try Task.checkCancellation()
        let id = UUID()
        let storedName = safeFilename(name)
        let folderName = id.uuidString
        let folder = staging.appending(path: folderName, directoryHint: .isDirectory)
        let file = folder.appending(path: storedName, directoryHint: .notDirectory)
        let fm = FileManager.default
        do {
            try createRootAndDirectory(staging)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { throw openError(errno) }
                let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                let count: Int64
                do {
                    count = try write(output)
                    try Task.checkCancellation()
                    try output.synchronize()
                    try output.close()
                } catch {
                    try? output.close()
                    throw error
                }
                let info = AttachmentInfo(id: id, originalFileName: name, storedFileName: storedName,
                                          relativePath: folderName + "/" + storedName, contentType: type.identifier,
                                          fileSize: count, createdAt: .now)
                return StagedAttachment(info: info)
            } catch {
                try? fm.removeItem(at: folder)
                throw error
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw AttachmentError.fileOperation(error)
        }
    }

    private func createRootAndDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        for path in [root, directory] {
            if !fm.fileExists(atPath: path.path) {
                do { try fm.createDirectory(at: path, withIntermediateDirectories: false) }
                catch let error as CocoaError where error.code == .fileWriteFileExists {
                    // Another import may have created this directory between the existence check and mkdir.
                }
            }
            try requireDirectory(path)
        }
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AttachmentError.invalidStoragePath }
    }

    private func folderName(for info: AttachmentInfo) -> String? {
        let components = info.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, UUID(uuidString: String(components[0])) != nil,
              validFilename(info.storedFileName), components[1] == info.storedFileName else { return nil }
        return String(components[0])
    }

    private func folderURL(for info: AttachmentInfo, isStaged: Bool) throws -> URL {
        guard let name = folderName(for: info) else { throw AttachmentError.invalidStoragePath }
        let base = isStaged ? staging : managed
        try requireDirectory(root)
        try requireDirectory(base)
        let folder = base.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) { try requireDirectory(folder) }
        return folder
    }

    private func safeFilename(_ value: String) -> String {
        let name = value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        return validFilename(name) ? name : "Attachment"
    }

    private func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 &&
            !name.contains("/") && !name.contains("\0")
    }

    private func removeFolder(for info: AttachmentInfo, isStaged: Bool) {
        do {
            let folder = try folderURL(for: info, isStaged: isStaged)
            try FileManager.default.removeItem(at: folder)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        } catch {
            NSLog("LumaTodo attachment cleanup: %@", error.localizedDescription)
        }
    }

    private func clean(_ directory: URL, keeping names: Set<String>) {
        let fm = FileManager.default
        do {
            guard fm.fileExists(atPath: directory.path) else { return }
            try requireDirectory(root)
            try requireDirectory(directory)
            let folders = try fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil && !names.contains(folder.lastPathComponent) {
                do {
                    try requireDirectory(folder)
                    try fm.removeItem(at: folder)
                } catch {
                    NSLog("LumaTodo attachment orphan cleanup: %@", error.localizedDescription)
                }
            }
        } catch {
            NSLog("LumaTodo attachment storage reconciliation: %@", error.localizedDescription)
        }
    }

    private func openError(_ code: Int32) -> AttachmentError {
        switch code {
        case ENOENT, ENOTDIR: .sourceMissing
        case EACCES, EPERM: .permissionDenied
        case ELOOP: .invalidFile
        case ENOSPC, EDQUOT: .diskFull
        default: .copyFailed
        }
    }
}
