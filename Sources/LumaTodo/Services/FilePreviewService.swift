import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum FilePreviewService {
    enum PreviewError: Error {
        case unreadable, damaged, unsupported, executable, noApplication

        func message(_ words: Words) -> String {
            switch self {
            case .unreadable:
                words("无法读取应用中的附件副本。", "The imported attachment cannot be read.")
            case .damaged:
                words("此文件无法预览。它可能已损坏，也可以尝试在关联应用中打开。", "This file could not be previewed. It may be damaged. You can try opening it in its default app.")
            case .unsupported:
                words("快速查看无法预览此格式。你可以尝试在关联应用中打开。", "Quick Look cannot preview this format. You can try opening it in its default app.")
            case .executable:
                words("LumaTodo 不会启动可执行附件。你可以在 Finder 中查看它。", "LumaTodo will not launch executable attachments. You can reveal this file in Finder.")
            case .noApplication:
                words("macOS 无法通过关联应用打开此文件。", "macOS could not open this file with its default app.")
            }
        }
    }

    static func checkPreview(_ url: URL, type: UTType?) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw PreviewError.unreadable }
            // Quick Look handles unfamiliar formats. Detect broken common documents before asking it to preview.
            if type?.conforms(to: .image) == true {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetCount(source) > 0 else { throw PreviewError.damaged }
            } else if type?.conforms(to: .pdf) == true {
                guard let document = CGPDFDocument(url as CFURL),
                      document.isEncrypted || document.numberOfPages > 0 else { throw PreviewError.damaged }
            }
        }.value
        if type == nil || type == .data || type == .item || type?.conforms(to: .archive) == true {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 32, height: 32),
                                                       scale: 1, representationTypes: [.thumbnail, .lowQualityThumbnail])
            do {
                _ = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } catch {
                throw PreviewError.unsupported
            }
        }
    }

    static func thumbnail(_ url: URL, pixels: Int) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCache: false
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    @MainActor
    static func open(_ url: URL, type: UTType?) async throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw PreviewError.unreadable }
        let launcherExtensions: Set<String> = ["app", "command", "workflow", "scpt", "applescript", "tool"]
        if type?.conforms(to: .executable) == true || type?.conforms(to: .application) == true
            || launcherExtensions.contains(url.pathExtension.lowercased()) {
            throw PreviewError.executable
        }
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: url) else { throw PreviewError.noApplication }
        let launchers: Set<String> = ["org.python.PythonLauncher", "com.apple.Terminal", "com.apple.Automator Runner"]
        if let id = Bundle(url: application)?.bundleIdentifier, launchers.contains(id) {
            throw PreviewError.executable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
        } catch {
            throw PreviewError.noApplication
        }
    }

    @MainActor
    static func reveal(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw PreviewError.unreadable }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
