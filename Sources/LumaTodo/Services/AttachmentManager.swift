import Foundation
import UniformTypeIdentifiers

struct AttachmentImportFailure: Sendable {
    let name: String
    let error: AttachmentError
}

struct AttachmentImportResult: Sendable {
    var imported: [StagedAttachment] = []
    var failures: [AttachmentImportFailure] = []
}

enum AttachmentError: Error, Equatable, Sendable {
    case sourceMissing
    case permissionDenied
    case invalidFile
    case tooLarge
    case diskFull
    case copyFailed
    case managedFileUnavailable
    case invalidStoragePath
    case invalidChange

    static func fileOperation(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteOutOfSpace: return .diskFull
            case .fileReadNoPermission, .fileWriteNoPermission: return .permissionDenied
            case .fileReadNoSuchFile, .fileNoSuchFile: return .sourceMissing
            default: break
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying != error {
            return fileOperation(underlying)
        }
        if error.domain == NSPOSIXErrorDomain {
            switch error.code {
            case Int(POSIXErrorCode.ENOSPC.rawValue), Int(POSIXErrorCode.EDQUOT.rawValue): return .diskFull
            case Int(POSIXErrorCode.ENOENT.rawValue): return .sourceMissing
            case Int(POSIXErrorCode.EPERM.rawValue), Int(POSIXErrorCode.EACCES.rawValue): return .permissionDenied
            default: break
            }
        }
        return .copyFailed
    }

    func message(_ words: Words) -> String {
        switch self {
        case .sourceMissing: words("原文件已不存在。", "The source file no longer exists.")
        case .permissionDenied: words("无法读取或写入此附件。请检查文件访问权限。", "Check file access permissions and try again.")
        case .invalidFile: words("请选择普通文件或粘贴图片。", "Choose a regular file or paste an image.")
        case .tooLarge: words("单个附件上限为 50 MB。", "Each attachment can be up to 50 MB.")
        case .diskFull: words("磁盘空间不足，无法保存附件。", "Free some disk space to save this attachment.")
        case .copyFailed: words("附件复制失败。请重试。", "The attachment could not be copied. Try again.")
        case .managedFileUnavailable: words("找不到此附件的本地副本，或该副本无法读取。", "The managed copy is missing or unreadable.")
        case .invalidStoragePath: words("附件存储位置不可用。", "The attachment storage location is unavailable.")
        case .invalidChange: words("附件已发生变化。请重新打开任务后再试。", "Reopen the task to apply your attachment changes.")
        }
    }
}

struct AttachmentManager: Sendable {
    private let storage: FileStorageService

    init(databaseURL: URL) {
        storage = FileStorageService(databaseURL: databaseURL)
    }

    func importFiles(_ urls: [URL]) async -> AttachmentImportResult {
        let operation = Task.detached(priority: .userInitiated) {
            var result = AttachmentImportResult()
            for url in urls {
                do {
                    result.imported.append(try storage.stage(file: url))
                } catch is CancellationError {
                    storage.discard(result.imported)
                    return AttachmentImportResult()
                } catch {
                    result.failures.append(.init(name: url.lastPathComponent, error: .fileOperation(error)))
                }
            }
            return result
        }
        return await withTaskCancellationHandler {
            let result = await operation.value
            if Task.isCancelled {
                storage.discard(result.imported)
                return AttachmentImportResult()
            }
            return result
        } onCancel: {
            operation.cancel()
        }
    }

    func importImage(_ data: Data, name: String, contentType: UTType) async throws -> StagedAttachment {
        let operation = Task.detached(priority: .userInitiated) {
            try storage.stage(image: data, name: name, type: contentType)
        }
        return try await withTaskCancellationHandler {
            let item = try await operation.value
            if Task.isCancelled {
                storage.discard([item])
                throw CancellationError()
            }
            return item
        } onCancel: {
            operation.cancel()
        }
    }

    func url(for info: AttachmentInfo) throws -> URL { try storage.fileURL(for: info, isStaged: false) }
    func url(for item: StagedAttachment) throws -> URL { try storage.fileURL(for: item.info, isStaged: true) }
    func discard(_ items: [StagedAttachment]) { storage.discard(items) }

    func promote(_ items: [StagedAttachment]) throws { try storage.promote(items) }
    func restoreStaging(_ items: [StagedAttachment]) { storage.restoreStaging(items) }
    func removeManaged(_ info: AttachmentInfo) { storage.removeManaged(info) }
    func reconcile(committed: [AttachmentInfo]) { storage.reconcile(committed: committed) }
}
