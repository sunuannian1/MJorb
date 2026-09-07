import SwiftUI

struct HistoryRootView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    filterSection
                    statsSection
                    recordsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.allRecords.isEmpty)
                }
            }
            .background(Color.sealBackground.ignoresSafeArea())
            .task {
                await viewModel.load()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task { await viewModel.reloadData() }
            }
            .confirmationDialog("清空历史记录", isPresented: $showingClearConfirmation) {
                Button("清空全部", role: .destructive) {
                    Task { await viewModel.clearAllHistory() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作将删除所有签名和续签历史记录，无法恢复。")
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("历史记录")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.primary)
            Text("查看签名和续签历史")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
        }
    }

    // MARK: - Filter Tabs

    private var filterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(HistoryViewModel.HistoryFilter.allCases) { item in
                    filterTab(item)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func filterTab(_ item: HistoryViewModel.HistoryFilter) -> some View {
        let isSelected = viewModel.filter == item
        return Button {
            Task { await viewModel.applyFilter(item) }
        } label: {
            Text(item.rawValue)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? .white : Color.sealTextSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Color.sealAccent : Color.sealSurface)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 12) {
            statCard(title: "总记录", value: "\(viewModel.totalSigningCount)", color: .primary)
            statCard(title: "成功", value: "\(viewModel.successCount)", color: .green)
            statCard(title: "失败", value: "\(viewModel.failureCount)", color: .red)
        }
    }

    private func statCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.sealSurface)
        )
    }

    // MARK: - Records List

    @ViewBuilder
    private var recordsSection: some View {
        if viewModel.isEmpty {
            emptyStateView
        } else {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.visibleRecords.enumerated()), id: \.element.id) { index, entry in
                    HistoryRowView(entry: entry)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    if index < viewModel.visibleRecords.count - 1 {
                        Divider()
                            .padding(.leading, 56)
                            .padding(.trailing, 16)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.sealSurface)
            )
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.sealTextSecondary)
            Text("暂无历史记录")
                .font(.headline)
                .foregroundStyle(Color.sealTextSecondary)
            Text("签名或续签应用后，记录将显示在这里")
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - History Row

struct HistoryRowView: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            // Status Icon
            Image(systemName: entry.statusIcon)
                .font(.system(size: 22))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.appDisplayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.isCurrent {
                        Text("当前")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                    }
                }
                Text(entry.typeTitle)
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                if let teamName = entry.teamName, !teamName.isEmpty {
                    Text(teamName)
                        .font(.caption)
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(1)
                }
                if let error = entry.details, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(relativeDateString(from: entry.timestamp))
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                if let expiry = entry.expiryDate {
                    Text("到期: \(shortDateString(from: expiry))")
                        .font(.caption)
                        .foregroundStyle(expiryColor(for: expiry))
                }
            }
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .success: return .green
        case .failure: return .red
        case .inProgress: return .blue
        }
    }

    private func expiryColor(for date: Date) -> Color {
        if date < Date() { return .red }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days <= 3 { return .orange }
        return Color.sealTextSecondary
    }

    private func relativeDateString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func shortDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }
}
