import SwiftUI

struct StorageMaintenanceView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var confirmsTemporaryClear = false
    @State private var confirmsUnusedClear = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                summaryCard
                usageCard
                actionCard
                dangerNote
            }
            .padding(20)
        }
        .navigationTitle("存储与维护")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refreshStorageUsage() }
        .refreshable { await viewModel.refreshStorageUsage() }
        .confirmationDialog(
            "清理临时缓存？",
            isPresented: $confirmsTemporaryClear,
            titleVisibility: .visible
        ) {
            Button("清理临时缓存", role: .destructive) {
                Task { await viewModel.clearTemporaryFiles() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除签名工作区、临时导入目录和失败后残留的临时文件。")
        }
        .confirmationDialog(
            "清理未使用文件？",
            isPresented: $confirmsUnusedClear,
            titleVisibility: .visible
        ) {
            Button("清理未使用文件", role: .destructive) {
                Task { await viewModel.clearUnusedStorageFiles() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清理临时缓存和没有被本地记录引用的孤立文件。已安装 App 的签名缓存、Apple ID 凭据和设备配对信息不会删除。")
        }
        .sealScreenBackground()
    }

    private var summaryCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Color.sealAccent)
            Text(viewModel.storageUsage.total.sealFormattedByteCount)
                .font(.title2.weight(.semibold))
            Text("Seal 当前占用")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    private var usageCard: some View {
        VStack(spacing: 0) {
            usageRow("导入的 IPA", viewModel.storageUsage.originalIPAs)
            Divider()
            usageRow("签名缓存", viewModel.storageUsage.signedIPAs)
            Divider()
            usageRow("图标文件", viewModel.storageUsage.iconFiles)
            Divider()
            usageRow("本地记录", viewModel.storageUsage.records)
            Divider()
            usageRow("临时缓存", viewModel.storageUsage.temporary)
            Divider()
            usageRow("孤立文件", viewModel.storageUsage.orphaned)
        }
        .padding(.horizontal, 16)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    private var actionCard: some View {
        VStack(spacing: 12) {
            Button("清理临时缓存") { confirmsTemporaryClear = true }
                .sealPrimaryAction(cornerRadius: 12)
            Button("清理未使用文件") { confirmsUnusedClear = true }
                .sealOutlineAction(cornerRadius: 12)
        }
    }

    private var dangerNote: some View {
        Text("签名缓存、Apple ID 凭据、证书和设备配对信息不会在这里清理。")
            .font(.footnote)
            .foregroundStyle(Color.sealTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassSurface(cornerRadius: 16)
    }

    private func usageRow(_ title: String, _ value: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.sealFormattedByteCount)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(minHeight: 54)
    }
}
