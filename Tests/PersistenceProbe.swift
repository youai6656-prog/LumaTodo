import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum PersistenceProbe {
    private static let deadline = Date(timeIntervalSince1970: 1_800_000_000)
    private static let week: TimeInterval = 7 * 86_400
    private static let firstJava = "class ExceptionDemo { int example() { return 1; } }\n"
    private static let secondJava = "class ExceptionDemo { int example() { return 22; } }\n"

    @MainActor static func main() async {
        do {
            let database = URL(fileURLWithPath: CommandLine.arguments[2])
            let store = try TaskStore(url: database)
            switch CommandLine.arguments[1] {
            case "write":
                var draft = TaskDraft(title: "重启持久化验证")
                draft.due = deadline
                draft.hasTime = true
                draft.leads = [0, 10]
                draft.independentReminders = [IndependentReminder(fire: deadline.addingTimeInterval(1200))]
                let task = try store.save(draft, now: deadline.addingTimeInterval(-3600))
                try store.snooze(task, occurrence: deadline, minutes: 10, now: deadline)
            case "read":
                guard let task = store.items.first, store.items.count == 1, task.title == "重启持久化验证",
                      task.due == deadline, task.leads == [0, 10],
                      task.snoozes.first?.fire == deadline.addingTimeInterval(600),
                      task.independentReminders.map(\.fire) == [deadline.addingTimeInterval(1200)],
                      store.item(task.id) === task else { throw ProbeError("Reopened task fields differ from saved values") }
                try store.complete(task)
                try check(task.isCompleted, "Completion was not saved")
                let source = database.deletingLastPathComponent().appending(path: "appended.md")
                let content = Data("Created and attached after reopening the database".utf8)
                try content.write(to: source)
                let importResult = await store.attachmentManager.importFiles([source])
                try check(importResult.imported.count == 1 && importResult.failures.isEmpty,
                          "Reopened 1.2 store could not stage a file for a new task")
                let added = try store.save(TaskDraft(title: "重启后追加的任务"),
                                           attachments: AttachmentChanges(adding: importResult.imported))
                guard let info = store.attachments(for: added.id).first else {
                    throw ProbeError("Reopened 1.2 store did not add a task and attachment")
                }
                let managed = try store.attachmentManager.url(for: info)
                try check(try Data(contentsOf: managed) == content && store.items.count == 2,
                          "Appending a new task to a reopened 1.2 store changed the previous task")
            case "delete-appended":
                guard let added = store.items.first(where: { $0.title == "重启后追加的任务" }),
                      let original = store.items.first(where: { $0.title == "重启持久化验证" }),
                      let info = store.attachments(for: added.id).first,
                      store.items.count == 2, original.isCompleted else {
                    throw ProbeError("New task attachment or original task did not persist across a second restart")
                }
                let managed = try store.attachmentManager.url(for: info)
                try check(try String(contentsOf: managed, encoding: .utf8) == "Created and attached after reopening the database",
                          "Appended attachment contents changed after reopening")
                try store.delete(added)
                try check(store.items.count == 1 && store.items.first === original
                    && !FileManager.default.fileExists(atPath: managed.path), "Deleting the appended task affected the original")
            case "delete":
                guard let task = store.items.first, store.items.count == 1, task.isCompleted,
                      task.snoozes.isEmpty else { throw ProbeError("Reopened completed task or snooze differs") }
                try store.delete(task)
            case "empty":
                try check(store.items.isEmpty, "Deleted task still exists after reopening")
            case "migrate-and-attach":
                try await migrateAndAttach(store, in: database.deletingLastPathComponent())
            case "reopen-and-remove":
                try reopenAndRemove(store)
            case "delete-with-attachments":
                try deleteWithAttachments(store)
            case "verify-deletion":
                try check(legacySeries(in: store) == nil, "Deleted legacy series still exists")
                try check(store.items.count == 2 && store.items.allSatisfy(\.isCompleted), "Deleting the series changed its historical tasks")
                try check(store.items.allSatisfy { store.attachments(for: $0.id).isEmpty }, "Attachment metadata remains")
            default:
                throw ProbeError("Unknown persistence test operation")
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func legacySeries(in store: TaskStore) -> TaskItem? {
        store.items.first { $0.title == "1.1 fixture · weekly" && !$0.isCompleted }
    }

    @MainActor private static func verifyLegacyFields(_ store: TaskStore) throws -> TaskItem {
        guard let series = legacySeries(in: store),
              let history = store.items.first(where: { $0.originID == series.id }),
              let completed = store.items.first(where: { $0.title == "1.1 fixture · completed" }) else {
            throw ProbeError("Migration lost a legacy task, recurrence, completion, or series reference")
        }
        try check(store.items.count == 3 && series.notes == "迁移前的任务描述" && series.tags == "legacy,repeat"
            && series.priority == .high && series.due == deadline.addingTimeInterval(week) && series.hasTime
            && series.rule == RepeatRule(kind: .weekly) && series.repeatAnchor == deadline && series.leads == [0, 10]
            && series.snoozes.count == 1 && series.snoozes.first?.fire == deadline.addingTimeInterval(600)
            && series.snoozes.first?.occurrence == deadline.addingTimeInterval(week),
            "Migration changed task fields or the legacy snooze payload")
        try check(history.completedAt == deadline && history.due == deadline && history.originScheduleID == series.scheduleID
            && history.previousDue == deadline && history.advancedDue == series.due && completed.completedAt == deadline,
            "Migration changed completion history")
        return series
    }

    @MainActor private static func migrateAndAttach(_ store: TaskStore, in directory: URL) async throws {
        let series = try verifyLegacyFields(store)
        try check(store.items.allSatisfy { store.attachments(for: $0.id).isEmpty }, "Legacy tasks unexpectedly acquired attachments")
        let source = directory.appending(path: "Originals")
        try FileManager.default.createDirectory(at: source.appending(path: "Duplicate"), withIntermediateDirectories: true)
        let pdf = source.appending(path: "Assignment.pdf")
        let png = source.appending(path: "Notes.png")
        let java = source.appending(path: "ExceptionDemo.java")
        let duplicate = source.appending(path: "Duplicate/ExceptionDemo.java")
        try makeReadables(pdf: pdf, png: png)
        try firstJava.write(to: java, atomically: true, encoding: .utf8)
        try secondJava.write(to: duplicate, atomically: true, encoding: .utf8)

        let manager = store.attachmentManager
        let batch = await manager.importFiles([pdf, png, java])
        try check(batch.failures.isEmpty && batch.imported.count == 3,
                  "Three-file import staged \(batch.imported.count), failures: \(batch.failures.map { "\($0.name): \($0.error)" })")
        let sameName = await manager.importFiles([duplicate])
        try check(sameName.failures.isEmpty && sameName.imported.count == 1, "A duplicate name did not stage")

        let before = series.scheduleID
        try store.save(TaskDraft(task: series), editing: series,
                       attachments: AttachmentChanges(adding: batch.imported + sameName.imported),
                       now: deadline.addingTimeInterval(600))
        try check(series.scheduleID == before && store.attachments(for: series.id).count == 4,
                  "An attachment-only edit changed the notification schedule or lost a file")
        let cancelled = await manager.importFiles([pdf])
        try check(cancelled.failures.isEmpty && cancelled.imported.count == 1, "Cancel fixture was not staged")
        let stagedURLs = try cancelled.imported.map { try manager.url(for: $0) }
        manager.discard(cancelled.imported)
        try check(stagedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
            && store.attachments(for: series.id).count == 4, "Discard did not remove only the staged file")
        try FileManager.default.removeItem(at: source)
    }

    @MainActor private static func reopenAndRemove(_ store: TaskStore) throws {
        let series = try verifyLegacyFields(store)
        let attachments = store.attachments(for: series.id)
        let manager = store.attachmentManager
        try check(attachments.count == 4 && Set(attachments.map(\.relativePath)).count == 4,
                  "Attachments were lost or both files ended up at the same path after reopening")
        guard let pdf = attachments.first(where: { $0.originalFileName == "Assignment.pdf" }),
              let png = attachments.first(where: { $0.originalFileName == "Notes.png" }) else {
            throw ProbeError("PDF or PNG metadata did not survive reopening")
        }
        let pdfData = try Data(contentsOf: manager.url(for: pdf))
        let pngData = try Data(contentsOf: manager.url(for: png))
        try check(pdf.contentType == UTType.pdf.identifier && pdfData.starts(with: Data("%PDF".utf8)),
                  "Imported PDF copy is not readable")
        try check(png.contentType == UTType.png.identifier && pngData.starts(with: [137, 80, 78, 71]), "Imported PNG copy is not readable")
        let java = try attachments.filter { $0.originalFileName == "ExceptionDemo.java" }.map {
            ($0, try String(contentsOf: manager.url(for: $0), encoding: .utf8))
        }
        try check(Set(java.map { $0.1 }) == [firstJava, secondJava], "Same-name files did not keep distinct contents")
        guard let removed = java.first(where: { $0.1 == firstJava })?.0 else { throw ProbeError("First Java attachment is missing") }
        let removedPath = try manager.url(for: removed)
        try store.save(TaskDraft(task: series), editing: series, attachments: AttachmentChanges(removing: [removed.id]),
                       now: deadline.addingTimeInterval(900))
        try check(!FileManager.default.fileExists(atPath: removedPath.path) && store.attachments(for: series.id).count == 3,
                  "Removing one file did not remove exactly one managed copy")
    }

    @MainActor private static func deleteWithAttachments(_ store: TaskStore) throws {
        let series = try verifyLegacyFields(store)
        let attachments = store.attachments(for: series.id)
        let manager = store.attachmentManager
        try check(attachments.count == 3, "A previously removed attachment reappeared")
        let files = try attachments.map { try manager.url(for: $0) }
        try store.delete(series)
        try check(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
                  "Deleting a task did not remove its managed copies")
    }

    private static func makeReadables(pdf: URL, png: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 120, height: 120)
        guard let document = CGContext(pdf as CFURL, mediaBox: &box, nil),
              let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ProbeError("Could not generate test PDF and PNG") }
        document.beginPDFPage(nil)
        document.setFillColor(red: 0, green: 0.5, blue: 0.5, alpha: 1)
        document.fill(box.insetBy(dx: 12, dy: 12))
        document.endPDFPage()
        document.closePDF()
        bitmap.setFillColor(red: 0, green: 0.5, blue: 0.5, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = bitmap.makeImage() else { throw ProbeError("Could not generate PNG pixels") }
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "Could not write generated PNG")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeError(message) }
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
