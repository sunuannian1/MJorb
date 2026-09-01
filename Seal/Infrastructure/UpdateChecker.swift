import Foundation

/// 启动更新通知检查器
/// 从 GitHub Releases 拉取最新版本，有更新时弹窗提示
struct UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "dmjorb/Seal"
    private let lastNotifiedVersionKey = "update_notifier.last_notified_version"

    /// 检查更新，返回需要展示的通知内容（无更新返回 nil）
    func check() async -> UpdateNotice? {
        // 测试模式：每次启动都弹
        return UpdateNotice(version: "test", title: "测试", message: "测试")
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Seal", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }

            // 本地版本
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

            // 如果最新版本和当前版本相同，不提示
            if tagName == currentVersion || tagName == "v\(currentVersion)" {
                return nil
            }

            // 已经通知过这个版本，不重复弹
            let lastNotified = UserDefaults.standard.string(forKey: lastNotifiedVersionKey)
            if lastNotified == tagName {
                return nil
            }

            // 标记已通知
            UserDefaults.standard.set(tagName, forKey: lastNotifiedVersionKey)

            return UpdateNotice(
                version: tagName,
                title: "测试",
                message: "测试"
            )
        } catch {
            return nil
        }
    }
}

struct UpdateNotice: Identifiable {
    let id = UUID()
    let version: String
    let title: String
    let message: String
}
