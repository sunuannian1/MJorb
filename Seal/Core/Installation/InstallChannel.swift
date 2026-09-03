import Foundation

protocol InstallChannel: Actor {
    func start() async throws -> String
    func diagnose() async -> InstallChannelDiagnostics
    func isReady() async -> Bool
    func storedDeviceIdentifier() async -> String?
    func reset() async
    func pushIpa(ipaData: Data, bundleID: String) async throws
    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws
    func verifyInstalled(bundleID: String) async throws
}

extension InstallChannel {
    func storedDeviceIdentifier() async -> String? { nil }
    func reset() async {}
}
