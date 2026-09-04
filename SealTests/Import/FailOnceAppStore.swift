import Foundation
@testable import Seal

actor FailOnceAppStore: AppStore {
    private var records: [AppRecord] = []
    private var shouldFailSave = true

    func fetchAll() -> [AppRecord] {
        records
    }

    func save(_ record: AppRecord) throws {
        // 多副本提交流程改用 save（不再调用 replaceImportedApp）。
        // 第一次保存发生在 databaseCommitPending 阶段、databaseRecord 赋值之前，
        // 此时抛错应映射为 SEAL-IPA-205 并保留 retryDraft；置位后重试即可成功。
        if shouldFailSave {
            shouldFailSave = false
            throw AppStoreError.invalidConfiguration
        }
        records.removeAll { $0.id == record.id }
        records.append(record)
    }

    func delete(id: UUID) {
        records.removeAll { $0.id == id }
    }

    func replaceImportedApp(_ record: AppRecord) throws -> [AppRecord] {
        let replaced = records.filter {
            $0.originalBundleIdentifier == record.originalBundleIdentifier
        }
        records.removeAll {
            $0.originalBundleIdentifier == record.originalBundleIdentifier
        }
        records.append(record)
        return replaced
    }
}
