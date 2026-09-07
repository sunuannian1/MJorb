import Foundation

/// 仅用于启动失败时的兜底存储，避免应用崩溃
actor FallbackAppStore: AppStore {
    private var storage: [UUID: AppRecord] = [:]

    func fetchAll() throws -> [AppRecord] {
        Array(storage.values).sorted { $0.importedAt > $1.importedAt }
    }

    func save(_ record: AppRecord) throws {
        storage[record.id] = record
    }

    func replaceImportedApp(_ record: AppRecord) throws -> [AppRecord] {
        storage[record.id] = record
        return Array(storage.values)
    }

    func delete(id: UUID) throws {
        storage[id] = nil
    }
}
