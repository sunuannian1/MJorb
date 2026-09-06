import Foundation

actor SealLogStore {
    private let fileURL: URL
    private let maximumEntries: Int
    private let fileProtector: any FileProtecting
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileURL: URL,
        maximumEntries: Int = 200,
        fileProtector: any FileProtecting = CompleteFileProtector()
    ) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
        self.fileProtector = fileProtector
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(
        category: SealLogEntry.Category,
        level: SealLogEntry.Level = .info,
        message: String,
        code: String? = nil
    ) throws {
        var values = try read()
        values.append(
            SealLogEntry(
                category: category,
                level: level,
                message: LogPrivacyRedactor.redact(message),
                code: code.map(LogPrivacyRedactor.redact)
            )
        )
        values = Array(values.suffix(maximumEntries))
        try write(values)
        // 错误日志镜像到 Documents（文件 App 可直接查看/分享），无需界面入口
        if level == .error {
            mirrorToDocuments()
        }
    }

    func entries() throws -> [SealLogEntry] {
        Array(try read().map(Self.redacted).reversed())
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func exportText() throws -> String {
        let formatter = ISO8601DateFormatter()
        return try entries().map { entry in
            let code = entry.code.map { " [\($0)]" } ?? ""
            return "\(formatter.string(from: entry.timestamp)) \(entry.level.rawValue.uppercased()) \(entry.category.rawValue)\(code) \(entry.message)"
        }.joined(separator: "\n")
    }

    private static func redacted(_ entry: SealLogEntry) -> SealLogEntry {
        SealLogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            category: entry.category,
            level: entry.level,
            message: LogPrivacyRedactor.redact(entry.message),
            code: entry.code.map(LogPrivacyRedactor.redact)
        )
    }

    /// 把最近日志镜像到 Documents（文件 App → 我的 iPhone → Seal → Seal-log.txt），
    /// 用户无需界面入口即可查看/分享完整诊断信息
    private func mirrorToDocuments() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let text = (try? exportText()) ?? ""
        try? text.write(
            to: documents.appendingPathComponent("Seal-log.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func read() throws -> [SealLogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode(
            [SealLogEntry].self,
            from: Data(contentsOf: fileURL)
        )
    }

    private func write(_ entries: [SealLogEntry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
        try fileProtector.protect(fileURL)
    }
}
