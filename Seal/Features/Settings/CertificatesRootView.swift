import SwiftUI

struct CertificatesRootView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let relatedApps: [AppRecord]

    @State private var isAddingAccount = false
    @State private var detailAccount: AppleAccountRecord?
    @State private var accountPendingDeletion: AppleAccountRecord?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.accounts.isEmpty {
                    emptyState
                } else {
                    accountsList
                }
            }
            .padding(20)
        }
        .navigationTitle("Apple ID 证书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { isAddingAccount = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fullScreenCover(isPresented: $isAddingAccount) {
            AddAccountView(viewModel: viewModel)
        }
        .confirmationDialog(
            "删除 Apple ID？",
            isPresented: Binding(
                get: { accountPendingDeletion != nil },
                set: { if !$0 { accountPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: accountPendingDeletion
        ) { account in
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteAccount(account) }
                accountPendingDeletion = nil
            }
            Button("取消", role: .cancel) { accountPendingDeletion = nil }
        } message: { account in
            let count = relatedApps.filter { $0.accountID == account.id }.count
            Text(
                count == 0
                    ? "删除后将移除此账号。"
                    : "该账号关联过 \(count) 个应用。删除不会卸载应用。"
            )
        }
        .navigationDestination(
            isPresented: Binding(
                get: { detailAccount != nil },
                set: { if !$0 { detailAccount = nil } }
            )
        ) {
            if let account = detailAccount {
                AppleAccountDetailView(
                    account: account,
                    relatedApps: relatedApps,
                    viewModel: viewModel
                )
            }
        }
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .task {
            await viewModel.load()
            await viewModel.refreshAppIDInventories()
            await viewModel.refreshCertificateInventories()
        }
        .refreshable {
            await viewModel.load(force: true)
            await viewModel.refreshAppIDInventories()
            await viewModel.refreshCertificateInventories()
        }
        .onChange(of: viewModel.requestedRoute) { route in
            guard route == .addAccount else { return }
            viewModel.requestedRoute = nil
            isAddingAccount = true
        }
        .sealScreenBackground()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(Color.sealAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.accounts.isEmpty ? "添加 Apple ID" : "当前签名账号")
                    .font(.title3.weight(.semibold))
                Text(activeAccountSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { isAddingAccount = true } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.sealAccent.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .glassSurface(cornerRadius: 24)
    }

    private var activeAccountSubtitle: String {
        guard let account = viewModel.activeAccount else {
            return "选择一个已验证账号用于新的 IPA 签名"
        }
        return viewModel.fullEmail(for: account)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(Color.sealAccent)
            Text("还没有 Apple ID")
                .font(.headline)
            Text("添加并验证后，可用于签名、续签和查看 Apple 账号状态。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassSurface(cornerRadius: 24)
    }

    private var accountsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.accounts.enumerated()), id: \.element.id) { index, account in
                accountRow(account)
                if index < viewModel.accounts.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.horizontal, 16)
        .glassSurface(cornerRadius: 24)
    }

    private func accountRow(_ account: AppleAccountRecord) -> some View {
        Button {
            detailAccount = account
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(viewModel.fullEmail(for: account))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 12)
                    Text(certificateStatusTitle(account))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(certificateStatusColor(account))
                        .lineLimit(1)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(accountDisplayName(account))
                        .font(.subheadline)
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 12)
                    Text(appIDQuotaTitle(account))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
            }
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除", role: .destructive) {
                accountPendingDeletion = account
            }
        }
    }

    private func isActive(_ account: AppleAccountRecord) -> Bool {
        viewModel.activeAccountID == account.id
    }

    private func accountDisplayName(_ account: AppleAccountRecord) -> String {
        let name = TeamNameDisplayFormatter.string(from: account.teamName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "名称未记录" : name
    }

    private func certificateStatusTitle(_ account: AppleAccountRecord) -> String {
        guard AccountAvailabilityPolicy.isSelectable(account) else { return "失效" }
        let serial = account.selectedCertificateSerialNumber ?? account.certificateSerialNumber
        guard let serial, serial.isEmpty == false else { return "未准备" }
        return "有效"
    }

    private func certificateStatusColor(_ account: AppleAccountRecord) -> Color {
        switch certificateStatusTitle(account) {
        case "有效":
            return Color.sealSuccess
        case "未准备":
            return Color.sealWarning
        default:
            return Color.sealDanger
        }
    }

    private func appIDQuotaTitle(_ account: AppleAccountRecord) -> String {
        if let inventory = viewModel.certificateInventory(for: account.id) {
            if account.isFreeTeam == true {
                return "已签名 \(inventory.usedBundleIDCount) / 10"
            }
            return "已签名 \(inventory.usedBundleIDCount) 个"
        }
        return account.isFreeTeam == true ? "已签名 — / 10" : "已签名 — 个"
    }
}
