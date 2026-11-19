import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LumaTodo

struct AttachmentInteractionTests {
    @MainActor @Test func pasteboardSeparatesTextFileAndImageRepresentations() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("file:///Users/example/not-a-Finder-file.pdf\n普通文字", forType: .string)
        #expect(AttachmentDrop.urls(from: pasteboard).isEmpty)
        #expect(AttachmentDrop.image(from: pasteboard) == nil)
        #expect(pasteboard.string(forType: .string)?.hasSuffix("普通文字") == true)

        let file = URL(fileURLWithPath: "/tmp/Finder original.java")
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([file as NSURL]))
        #expect(AttachmentDrop.urls(from: pasteboard) == [file])

        let image = try imageBytes()
        pasteboard.clearContents()
        #expect(pasteboard.setData(image, forType: .png))
        #expect(AttachmentDrop.urls(from: pasteboard).isEmpty)
        let (received, type) = try #require(AttachmentDrop.image(from: pasteboard))
        #expect(received == image)
        #expect(type == UTType.png)
    }

    @MainActor @Test func plainDescriptionFieldAdvertisesAndAcceptsAttachmentPasteTypes() throws {
        let field = DescriptionTextView()
        field.isRichText = false
        field.importsGraphics = false
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let png = try imageBytes()

        board.clearContents()
        #expect(board.setData(png, forType: .png))
        let type = try #require(board.availableType(from: field.readablePasteboardTypes))
        #expect(type == .png)
        var received: Data?
        field.onImage = { data, _ in received = data }
        #expect(field.readSelection(from: board, type: type))
        #expect(received == png)
        #expect(field.string.isEmpty)

        let file = URL(fileURLWithPath: "/tmp/Native file.txt")
        board.clearContents()
        #expect(board.writeObjects([file as NSURL]))
        var attached: [URL] = []
        field.onFiles = { attached = $0 }
        #expect(field.readSelection(from: board, type: .fileURL))
        #expect(attached == [file])
        #expect(field.string.isEmpty)
    }

    @MainActor @Test func fileDropLoadsOnlyNativeLocalFileRepresentations() async {
        let local = URL(fileURLWithPath: "/tmp/A Java file.java")
        let file = NSItemProvider(item: local as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let plain = NSItemProvider(item: "file:///tmp/not-a-real-file-URL.pdf" as NSString,
                                   typeIdentifier: UTType.plainText.identifier)
        let received = await AttachmentDrop.load([file, plain])
        #expect(received == [local])
    }

    @Test func previewChecksCommonFormatsAndDownsamplesImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LumaTodoPreview-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = directory.appending(path: "sample.png")
        try imageBytes().write(to: image)
        try await FilePreviewService.checkPreview(image, type: .png)
        let thumbnail = try #require(await FilePreviewService.thumbnail(image, pixels: 24))
        #expect(thumbnail.width <= 24 && thumbnail.height <= 24)

        let pdf = directory.appending(path: "valid.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 80, height: 80)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.endPDFPage()
        context.closePDF()
        try await FilePreviewService.checkPreview(pdf, type: .pdf)

        let damagedImage = directory.appending(path: "damaged.png")
        try Data("not a PNG".utf8).write(to: damagedImage)
        await #expect(throws: FilePreviewService.PreviewError.damaged) {
            try await FilePreviewService.checkPreview(damagedImage, type: .png)
        }
    }

    private func imageBytes() throws -> Data {
        // Create a small fixture with the system PNG encoder.
        let context = try #require(CGContext(data: nil, width: 72, height: 48, bitsPerComponent: 8,
                                            bytesPerRow: 288, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 72, height: 48))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
