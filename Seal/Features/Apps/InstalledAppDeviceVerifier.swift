import Foundation
@preconcurrency import Minimuxer

struct InstalledAppDeviceVerifier {
    static func isInstalled(bundleIdentifier: String) async throws -> Bool {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else {
            throw NSError(
                domain: "SealInstalledAppDeviceVerifier",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundle identifier"]
            )
        }

        return try await Task.detached(priority: .userInitiated) {
            // 查询前重置连接，避免使用已断开的RSD缓存连接导致误判
            Minimuxer.Install.resetProvider()
            return try Minimuxer.isAppInstalled(bundleId: identifier)
        }.value
    }
}
