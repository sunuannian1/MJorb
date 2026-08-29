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
            try Minimuxer.isAppInstalled(bundleId: identifier)
        }.value
    }
}
