import Combine
import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case signing = "签名"
        case renewal = "续签"

        var id: Self { self }

        var signingAction: SigningHistoryRecord.Action? {
            switch self {
            case .all: return nil
            case .signing: return .sign
            case .renewal: return .renew
            }
        }
    }

    @Published var filter: HistoryFilter = .all
    @Published private(set) var allRecords: [HistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isEmpty = false

    private let signingHistoryStore: SigningHistoryStore
    private let appStore: any AppStore

    init(signingHistoryStore: SigningHistoryStore, appStore: any AppStore) {
        self.signingHistoryStore = signingHistoryStore
        self.appStore = appStore
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await reloadData()
    }

    func reloadData() async {
        guard let signingRecords = try? await signingHistoryStore.records() else {
            allRecords = []
            isEmpty = true
            return
        }

        let filtered: [SigningHistoryRecord]
        if let action = filter.signingAction {
            filtered = signingRecords.filter { $0.action == action }
        } else {
            filtered = signingRecords
        }

        allRecords = filtered.map { record in
            HistoryEntry(
                id: record.id,
                type: record.action == .renew ? .renewal : .signing,
                appDisplayName: record.appName,
                bundleIdentifier: record.signedBundleIdentifier ?? record.originalBundleIdentifier,
                teamName: record.teamName,
                status: record.result == .success ? .success : .failure,
                timestamp: record.signedAt,
                details: record.errorReason,
                errorCode: record.errorCode,
                accountEmail: record.accountDisplayName,
                certificateName: record.provisioningProfileName,
                expiryDate: record.expiryDate,
                action: record.action,
                lifecycleStatus: record.lifecycleStatus
            )
        }
        isEmpty = allRecords.isEmpty
    }

    func applyFilter(_ newFilter: HistoryFilter) async {
        filter = newFilter
        await reloadData()
    }

    func clearAllHistory() async {
        try? await signingHistoryStore.clear()
        allRecords = []
        isEmpty = true
    }

    var visibleRecords: [HistoryEntry] { allRecords }

    var totalSigningCount: Int {
        allRecords.count
    }

    var successCount: Int {
        allRecords.filter { $0.status == .success }.count
    }

    var failureCount: Int {
        allRecords.filter { $0.status == .failure }.count
    }
}

// MARK: - History Entry Model

struct HistoryEntry: Identifiable, Equatable {
    enum EntryType: Equatable {
        case signing
        case installation
        case renewal
    }

    enum EntryStatus: Equatable {
        case success
        case failure
        case inProgress
    }

    let id: UUID
    let type: EntryType
    let appDisplayName: String
    let bundleIdentifier: String
    let teamName: String?
    let status: EntryStatus
    let timestamp: Date
    let details: String?
    let errorCode: String?
    let accountEmail: String?
    let certificateName: String?
    let expiryDate: Date?
    let action: SigningHistoryRecord.Action
    let lifecycleStatus: SigningHistoryRecord.LifecycleStatus?

    var statusIcon: String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .inProgress: return "arrow.triangle.2.circlepath"
        }
    }

    var typeTitle: String {
        action.displayTitle
    }

    var isCurrent: Bool {
        lifecycleStatus == .active
    }
}
