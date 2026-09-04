import Foundation

enum SigningCompletionMode: String, Equatable, Sendable {
    case signAndInstall
}

struct SigningSession: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case running(SigningStage)
        case succeeded(AppRecord)
        case failed(ImportFailure)
    }

    let id: UUID
    let app: AppRecord
    let account: AppleAccountRecord
    let requestedBundleIdentifier: String?
    // var：签名开始时可能为 nil（签名时才申请证书），证书确定后由回调回写，
    // 让进度/失败回看界面显示真实证书而非“未准备”。
    var selectedCertificateSerialNumber: String?
    let completionMode: SigningCompletionMode
    var allowsDroppingExtensions: Bool
    var status: Status

    init(
        id: UUID = UUID(),
        app: AppRecord,
        account: AppleAccountRecord,
        requestedBundleIdentifier: String? = nil,
        selectedCertificateSerialNumber: String? = nil,
        completionMode: SigningCompletionMode = .signAndInstall,
        allowsDroppingExtensions: Bool = false,
        status: Status
    ) {
        self.id = id
        self.app = app
        self.account = account
        self.requestedBundleIdentifier = requestedBundleIdentifier
        self.selectedCertificateSerialNumber = selectedCertificateSerialNumber
        self.completionMode = completionMode
        self.allowsDroppingExtensions = allowsDroppingExtensions
        self.status = status
    }
}
