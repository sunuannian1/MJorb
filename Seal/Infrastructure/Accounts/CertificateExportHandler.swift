import Foundation
import UIKit

/// 处理 LiveContainer 等外部应用通过 sidestore://certificate?callback_template=...
/// 请求导出当前签名证书（P12 + 密码），对齐 SideStore 官方行为。
///
/// 流程：
/// 1. 外部应用打开 sidestore://certificate?callback_template=...
/// 2. Seal 弹确认框"是否导出证书"
/// 3. 用户点 Export → 取当前活跃账号的 certificateP12 + password
/// 4. 替换 callback_template 中的 $(BASE64_CERT) 和 $(PASSWORD)
/// 5. 打开替换后的 callback URL，把证书回传给外部应用
@MainActor
final class CertificateExportHandler {
    private let keychain: KeychainVault
    private let signingPreferenceStore: SigningPreferenceStore

    init(keychain: KeychainVault, signingPreferenceStore: SigningPreferenceStore) {
        self.keychain = keychain
        self.signingPreferenceStore = signingPreferenceStore
    }

    /// 判断是否为证书导出请求
    func canHandle(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else {
            return false
        }
        return host == "certificate"
    }

    /// 处理证书导出请求，返回是否成功处理
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard canHandle(url) else { return false }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let callbackTemplate = queryItems.first(where: { $0.name.lowercased() == "callback_template" })?.value?.removingPercentEncoding else {
            return false
        }

        presentExportDialog(callbackTemplate: callbackTemplate)
        return true
    }

    // MARK: - Private

    private func presentExportDialog(callbackTemplate: String) {
        guard let topVC = UIApplication.shared.topViewController() else { return }

        let alert = UIAlertController(
            title: NSLocalizedString("导出证书", comment: ""),
            message: NSLocalizedString("是否将当前签名证书导出给外部应用？该应用将可以使用你的证书签名应用。", comment: ""),
            preferredStyle: .alert
        )

        let exportAction = UIAlertAction(title: NSLocalizedString("导出", comment: ""), style: .default) { [weak self] _ in
            Task { @MainActor in
                await self?.performExport(callbackTemplate: callbackTemplate, from: topVC)
            }
        }

        alert.addAction(exportAction)
        alert.addAction(UIAlertAction(title: NSLocalizedString("取消", comment: ""), style: .cancel))

        topVC.present(alert, animated: true)
    }

    private func performExport(callbackTemplate: String, from viewController: UIViewController) async {
        // 1. 取当前活跃账号 ID
        guard let activeAccountID = await signingPreferenceStore.activeAccountID() else {
            showToast("未找到活跃账号，请先在 Seal 中添加并选择签名账号", in: viewController)
            return
        }

        // 2. 从 Keychain 读取 AccountSecret
        guard let secret = try? await keychain.load(accountID: activeAccountID) else {
            showToast("无法读取账号凭据，请重新验证该 Apple ID", in: viewController)
            return
        }

        // 3. 检查证书和密码
        guard let p12Data = secret.certificateP12 else {
            showToast("当前账号尚未生成签名证书，请先完成一次签名", in: viewController)
            return
        }

        let password = secret.password ?? ""

        // 4. 校验 callback_template 包含占位符
        guard callbackTemplate.contains("$(BASE64_CERT)") else {
            showToast("回调地址缺少 $(BASE64_CERT) 占位符", in: viewController)
            return
        }

        // 5. Base64 编码 P12
        let base64Cert = p12Data.base64EncodedString()

        // 6. 替换占位符
        var urlStr = callbackTemplate
            .replacingOccurrences(of: "$(BASE64_CERT)", with: base64Cert, options: .literal)
        urlStr = urlStr
            .replacingOccurrences(of: "$(PASSWORD)", with: password, options: .literal)

        // 7. 打开 callback URL
        guard let callbackURL = URL(string: urlStr) else {
            showToast("回调地址无效", in: viewController)
            return
        }

        UIApplication.shared.open(callbackURL)
    }

    private func showToast(_ message: String, in viewController: UIViewController) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        viewController.present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            alert.dismiss(animated: true)
        }
    }
}

private extension UIApplication {
    func topViewController() -> UIViewController? {
        guard let windowScene = connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
