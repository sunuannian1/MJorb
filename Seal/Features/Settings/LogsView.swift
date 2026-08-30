import SwiftUI

struct LogsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var selectedCategory: SealLogEntry.Category? = nil
    @State private var isExporting = false

    private let categories: [SealLogEntry.Category?] = [
        nil, .account, .pairing, .signing, .installation, .renewal, .system
    ]

    private var categoryIDs: [String] {
        categories.map { $0?.rawValue ?? "all" }
    }

    private var filteredLogs: [SealLogEntry] {
        guard let category = selectedCategory else {
            return viewModel.logs
        }
        return viewModel.logs.filter { $0.category == category }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                            Button {
                                selectedCategory = category
                            } label: {
                                Text(categoryTitle(category))
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(selectedCategory == category ? Color.sealAccent.opacity(0.2) : Color.secondary.opacity(0.1))
                                    )
                                    .foregroundColor(selectedCategory == category ? .sealAccent : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                if filteredLogs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("暂无日志")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(filteredLogs) { entry in
                        logRow(entry)
                    }
                }
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        isExporting = true
                    } label: {
                        Label("导出日志", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.logs.isEmpty)

                    Button(role: .destructive) {
                        Task { await viewModel.clearLogs() }
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                    .disabled(viewModel.logs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isExporting) {
            ActivityView(activityItems: [viewModel.logExportText])
        }
        .task {
            await viewModel.load(force: true)
        }
    }

    private func logRow(_ entry: SealLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                levelIcon(entry.level)
                Text(categoryTitle(entry.category))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(timeString(entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(entry.message)
                .font(.subheadline)
                .foregroundColor(.primary)
            if let code = entry.code {
                Text("错误码: \(code)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func levelIcon(_ level: SealLogEntry.Level) -> some View {
        Group {
            switch level {
            case .info:
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            case .error:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
    }

    private func categoryTitle(_ category: SealLogEntry.Category?) -> String {
        guard let category else { return "全部" }
        switch category {
        case .account: return "账号"
        case .pairing: return "配对"
        case .signing: return "签名"
        case .installation: return "安装"
        case .renewal: return "续签"
        case .system: return "系统"
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
