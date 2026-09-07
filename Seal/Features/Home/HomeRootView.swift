import SwiftUI

struct HomeRootView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    accountStatusSection
                    signedAppsSummarySection
                    notificationConfigSection
                    if viewModel.expiringSoonCount > 0 {
                        expiringSoonBanner
                    }
                    quickActionsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.sealBackground.ignoresSafeArea())
            .task {
                await viewModel.load()
                await settingsViewModel.load()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task {
                    await viewModel.reloadData()
                    await viewModel.refreshPushAuthorizationStatus()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .homeTabReselected)) { _ in
                Task { await viewModel.reloadData() }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Image(systemName: "seal.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
                Text("Seal")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("iOS IPA 签名与安装工具")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
        }
    }

    // MARK: - Account Status

    private var accountStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "账号状态", icon: "person.badge.shield.checkmark")

            if viewModel.accounts.isEmpty {
                emptyAccountCard
            } else {
                accountCard
            }
        }
    }

    private var emptyAccountCard: some View {
        Button {
            NotificationCenter.default.post(name: .homeNavigateToSettings, object: SettingsRoute.accounts)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.sealAccent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未添加账号")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("添加 Apple ID 后即可开始签名安装应用")
                            .font(.caption)
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                    Spacer()
                }
                Text("添加 Apple ID")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.sealAccent, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.sealSurface)
            )
        }
        .buttonStyle(.plain)
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("已添加 \(viewModel.accounts.count) 个账号")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let email = viewModel.activeAccountEmail {
                        Text("当前: \(email)")
                            .font(.caption)
                            .foregroundStyle(Color.sealTextSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .homeNavigateToSettings, object: SettingsRoute.accounts)
                } label: {
                    Text("管理")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.sealAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.sealAccent.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.sealSurface)
        )
    }

    // MARK: - Signed Apps Summary

    private var signedAppsSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "已签名应用", icon: "app.badge.checkmark")

            if viewModel.hasSignedApps {
                signedAppsCard
            } else {
                emptyAppsCard
            }
        }
    }

    private var signedAppsCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(viewModel.totalSignedCount)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.sealAccent)
                Text("已安装应用")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if viewModel.expiringSoonCount > 0 {
                    Label("\(viewModel.expiringSoonCount) 即将到期", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                } else {
                    Label("全部有效", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.sealSurface)
        )
    }

    private var emptyAppsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.sealAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("还没有签名应用")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("前往「应用」标签导入 IPA")
                        .font(.caption)
                        .foregroundStyle(Color.sealTextSecondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.sealSurface)
        )
    }

    // MARK: - Notification Config

    private var notificationConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "到期通知", icon: "bell.badge")

            notificationStatusCard
        }
    }

    private var notificationStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: viewModel.notificationConfig.isEnabled ? "bell.fill" : "bell.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(viewModel.notificationConfig.isEnabled ? Color.sealAccent : Color.sealTextSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.notificationConfig.isEnabled ? "通知已开启" : "通知未配置")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    if viewModel.notificationConfig.isEnabled {
                        Text("将在到期前提醒")
                            .font(.caption)
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                }
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .homeNavigateToSettings, object: nil)
                } label: {
                    Text("配置")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.sealAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.sealAccent.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if viewModel.pushAuthorizationStatus == .denied || viewModel.pushAuthorizationStatus == .notDetermined {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                    Text(pushStatusMessage)
                        .font(.caption)
                        .foregroundStyle(Color.sealTextSecondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.sealSurface)
        )
    }

    private var pushStatusMessage: String {
        switch viewModel.pushAuthorizationStatus {
        case .denied:
            return "推送权限被拒绝，请在系统设置中开启"
        case .notDetermined:
            return "需要授权推送权限以接收到期提醒"
        default:
            return ""
        }
    }

    // MARK: - Expiring Soon Banner

    private var expiringSoonBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.orange)
            Text("\(viewModel.expiringSoonCount) 个应用即将在 3 天内到期")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 0.8)
        )
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "快捷操作", icon: "bolt.fill")

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                quickActionButton(title: "添加账号", icon: "person.badge.plus")
                quickActionButton(title: "配对设备", icon: "cable.connector")
                quickActionButton(title: "通知设置", icon: "bell.badge")
                quickActionButton(title: "存储维护", icon: "externaldrive")
            }
        }
    }

    private func quickActionButton(title: String, icon: String) -> some View {
        Button {
            NotificationCenter.default.post(name: .homeNavigateToSettings, object: nil)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.sealAccent)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.sealSurface)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.sealAccent)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }
}

extension Notification.Name {
    static let homeNavigateToSettings = Notification.Name("seal.homeNavigateToSettings")
}
