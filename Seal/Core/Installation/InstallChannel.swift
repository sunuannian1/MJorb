import Foundation

protocol InstallChannel: Actor {
    func start() async throws -> String
    func diagnose() async -> InstallChannelDiagnostics
    func isReady() async -> Bool
    func storedDeviceIdentifier() async -> String?
    func reset() async
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws
    func verifyInstalled(bundleID: String) async throws
    func stop() async
}


extension InstallChannel {
    func storedDeviceIdentifier() async -> String? { nil }
    func reset() async {}
    func stop() async {}
}
