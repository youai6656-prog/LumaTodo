import Foundation
import Observation
import SwiftData

struct AttachmentInfo: Identifiable, Hashable, Sendable {
    let id: UUID
    let originalFileName: String
    let storedFileName: String
    let relativePath: String
    let contentType: String
    let fileSize: Int64
    let createdAt: Date

    func copiedMetadata() -> AttachmentInfo {
        AttachmentInfo(id: UUID(), originalFileName: originalFileName, storedFileName: storedFileName,
                       relativePath: relativePath, contentType: contentType, fileSize: fileSize, createdAt: createdAt)
    }
}

struct StagedAttachment: Identifiable, Hashable, Sendable {
    let info: AttachmentInfo
    var id: UUID { info.id }
}

struct AttachmentChanges {
    var adding: [StagedAttachment] = []
    var removing: Set<UUID> = []
}

// taskID is a foreign key managed by TaskStore so the 1.1 TaskItem entity needs no schema changes.
final class Attachment: PersistentModel, Identifiable {
    static let detachedBacking = NativeBackingFactory(Attachment.self)

    var persistentBackingData: any BackingData<Attachment>
    private let registrar = ObservationRegistrar()

    static var schemaMetadata: [Schema.PropertyMetadata] {
        [
            .init(name: "id", keypath: \Attachment.id, metadata: Schema.Attribute(.unique)),
            .init(name: "taskID", keypath: \Attachment.taskID),
            .init(name: "originalFileName", keypath: \Attachment.originalFileName),
            .init(name: "storedFileName", keypath: \Attachment.storedFileName),
            .init(name: "relativePath", keypath: \Attachment.relativePath),
            .init(name: "contentType", keypath: \Attachment.contentType),
            .init(name: "fileSize", keypath: \Attachment.fileSize),
            .init(name: "createdAt", keypath: \Attachment.createdAt),
        ]
    }

    init(backingData: any BackingData<Attachment>) {
        persistentBackingData = backingData
    }

    convenience init(info: AttachmentInfo, taskID: UUID) {
        let data: any BackingData<Attachment> = Self.detachedBacking.make()
        data.setValue(forKey: \.id, to: info.id)
        data.setValue(forKey: \.taskID, to: taskID)
        data.setValue(forKey: \.originalFileName, to: info.originalFileName)
        data.setValue(forKey: \.storedFileName, to: info.storedFileName)
        data.setValue(forKey: \.relativePath, to: info.relativePath)
        data.setValue(forKey: \.contentType, to: info.contentType)
        data.setValue(forKey: \.fileSize, to: info.fileSize)
        data.setValue(forKey: \.createdAt, to: info.createdAt)
        self.init(backingData: data)
    }

    private subscript<Value: Codable>(keyPath: ReferenceWritableKeyPath<Attachment, Value>) -> Value {
        get {
            registrar.access(self, keyPath: keyPath)
            return getValue(forKey: keyPath)
        }
        set {
            registrar.withMutation(of: self, keyPath: keyPath) {
                setValue(forKey: keyPath, to: newValue)
            }
        }
    }

    var id: UUID {
        get { self[\.id] }
        set { self[\.id] = newValue }
    }

    var taskID: UUID {
        get { self[\.taskID] }
        set { self[\.taskID] = newValue }
    }

    var originalFileName: String {
        get { self[\.originalFileName] }
        set { self[\.originalFileName] = newValue }
    }

    var storedFileName: String {
        get { self[\.storedFileName] }
        set { self[\.storedFileName] = newValue }
    }

    var relativePath: String {
        get { self[\.relativePath] }
        set { self[\.relativePath] = newValue }
    }

    var contentType: String {
        get { self[\.contentType] }
        set { self[\.contentType] = newValue }
    }

    var fileSize: Int64 {
        get { self[\.fileSize] }
        set { self[\.fileSize] = newValue }
    }

    var createdAt: Date {
        get { self[\.createdAt] }
        set { self[\.createdAt] = newValue }
    }

    var info: AttachmentInfo {
        AttachmentInfo(id: id, originalFileName: originalFileName, storedFileName: storedFileName,
                       relativePath: relativePath, contentType: contentType, fileSize: fileSize, createdAt: createdAt)
    }
}


// The native factory can return an unbound placeholder after a disk store is opened.
// Capture its concrete metatype up front and allocate fresh native storage through BackingData.
struct NativeBackingFactory<Model: PersistentModel>: @unchecked Sendable {
    private let backingType: any BackingData<Model>.Type

    init(_ model: Model.Type) {
        let template: any BackingData<Model> = model.createBackingData()
        backingType = type(of: template)
    }

    func make() -> any BackingData<Model> { backingType.init(for: Model.self) }
}
