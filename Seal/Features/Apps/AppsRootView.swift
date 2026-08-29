import SwiftUI
import UniformTypeIdentifiers

struct AppsRootView: View {
    private enum ListMode: String, Identifiable, CaseIterable {
        case unsigned = "待签名"
        case installed = "已安装"

        var id: Self { self }
    }

    @ObservedObject var viewModel: AppsViewModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var sealTitleSize = 38
    @Namespace private var tabIndicatorNamespace
    @State private var mode: ListMode = .installed
    @State private var detailApp: AppRecord?
    @State private var pendingDeleteApp: AppRecord?
    @State private var installedActionApp: AppRecord?
    @State private var operationAppID: UUID?
    @State private var didResolveInitialMode = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                header
                modeTabs
                appPager
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $viewModel.isImporterPresented,
                allowedContentTypes: [.item, .data, .archive, .ipaArchive, .zipArchive]
            ) { result in
                switch result {
                case .success(let url):
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { mode = .unsigned }
                    Task { await viewModel.importSelectedFile(url) }
                case .failure(let error): viewModel.handleImporterFailure(error)
                }
            }
            .sheet(isPresented: $viewModel.isImportSheetPresented, onDismiss: cancelDraftIfNeeded) {
                if let draft = viewModel.sheetDraft {
                    ImportConfirmationView(
                        draft: draft,
                        isCommitting: viewModel.phase == .committing,
                        failure: viewModel.sheetFailure,
                        onCancel: { Task { await viewModel.cancelImport() } },
                        onPrimaryAction: {
                            Task {
                                if viewModel.sheetFailure == nil { await viewModel.confirmImport() }
                                else { await viewModel.retryImport() }
                            }
                        }
                    )
                    .presentationDetents([.medium, .large])
                }
            }
            .sheet(item: $viewModel.selectedOperationApp, onDismiss: operationSheetDismissed) { app in
                AppSigningSheet(
                    app: app,
                    viewModel: viewModel,
                    onFinish: { _ in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { mode = .installed }
                    },
                    onDelete: {
                        pendingDeleteApp = app
                    }
                )
                .presentationDetents(operationDetents(for: app))
            }
            .sheet(item: $installedActionApp) { app in
                InstalledAppActionSheet(
                    app: app,
                    viewModel: viewModel,
                    onRenew: {
                        operationAppID = app.id
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            await viewModel.beginRenewalDirectly(for: app)
                        }
                    },
                    onShowDetail: {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(200))
                            detailApp = app
                        }
                    }
                )
                .presentationDetents(installedOperationDetents)
            }
            .sheet(item: $viewModel.accountSelectionApp) { app in
                AccountSelectionView(
                    app: app,
                    accounts: viewModel.availableAccounts,
                    fullEmail: { viewModel.fullEmail(for: $0) },
                    onSelect: { viewModel.selectAccount($0, for: app) }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $viewModel.batchRefreshSession) { _ in
                BatchRefreshView(viewModel: viewModel)
                    .presentationDetents([.height(620), .large])
            }
            .sheet(item: $detailApp) { app in
                AppDetailView(appID: app.id, viewModel: viewModel)
                    .presentationDetents([.medium, .large])
            }
            .alert(deleteAlertTitle, isPresented: Binding(
                get: { pendingDeleteApp != nil },
                set: { if !$0 { pendingDeleteApp = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDeleteApp = nil }
                Button("删除", role: .destructive) {
                    guard let app = pendingDeleteApp else { return }
                    pendingDeleteApp = nil
                    Task { _ = await viewModel.delete(app) }
                }
            } message: {
                Text(deleteAlertMessage)
            }
            .alert(item: rootAlertFailure) { failure in
                standardAlert(failure)
            }
            .task {
                await settingsViewModel.load()
                await viewModel.load()
                await viewModel.refreshInstalledApps(userInitiated: false)
                resolveInitialModeIfNeeded()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task {
                    await viewModel.refreshInstalledApps(userInitiated: false)
                    if mode == .unsigned {
                        await viewModel.refreshUnsignedApps()
                    }
                }
            }
            .onChange(of: viewModel.importCompletionCount) { _ in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    mode = viewModel.lastImportCompletedInstalledApp ? .installed : .unsigned
                }
            }
        }
        .sealScreenBackground()
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Seal")
                .font(.system(size: sealTitleSize, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button {
                viewModel.presentImporter()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.sealAccent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("导入应用")
            .accessibilityIdentifier("import-toolbar-button")
            .disabled(viewModel.phase != .idle)
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 28) {
            modeButton(.unsigned, count: viewModel.unsignedApps.count)
            modeButton(.installed, count: viewModel.installedApps.count)
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: mode)
    }

    private func modeButton(_ item: ListMode, count: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { mode = item }
        } label: {
            VStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Text(item.rawValue)
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(count)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.sealTextSecondary)
                }
                ZStack {
                    Capsule().fill(Color.clear).frame(height: 3)
                    if mode == item {
                        Capsule()
                            .fill(Color.sealAccent)
                            .frame(height: 3)
                            .matchedGeometryEffect(id: "apps-tab-indicator", in: tabIndicatorNamespace)
                    }
                }
            }
            .foregroundStyle(mode == item ? Color.sealAccent : Color.sealTextSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.rawValue)，\(count) 个")
        .accessibilityAddTraits(mode == item ? .isSelected : [])
    }

    private var appPager: some View {
        TabView(selection: $mode) {
            appPage(.unsigned, apps: viewModel.unsignedApps).tag(ListMode.unsigned)
            appPage(.installed, apps: viewModel.installedApps).tag(ListMode.installed)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("apps-stage-pager")
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: mode)
    }

    private func appPage(_ pageMode: ListMode, apps: [AppRecord]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(pageMode)
                    .frame(height: 38)
                appList(pageMode, apps: apps)
            }
            .padding(.bottom, 30)
        }
        .refreshable {
            await refreshAppsPage(pageMode)
        }
    }

    private func pageHeader(_ pageMode: ListMode) -> some View {
        HStack(alignment: .center) {
            Text(sectionTitle(for: pageMode))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if pageMode == .installed, viewModel.installedApps.isEmpty == false {
                batchRefreshMenu
            } else {
                Color.clear.frame(width: 1, height: 30)
            }
        }
    }

    @ViewBuilder
    private func appList(_ pageMode: ListMode, apps: [AppRecord]) -> some View {
        if pageMode == .unsigned, viewModel.phase == .preparing || viewModel.phase == .committing {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在读取 IPA")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 116)
            .sealListCard(cornerRadius: 18)
        } else if apps.isEmpty {
            emptyState(pageMode)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    Button {
                        openApp(app, in: pageMode)
                    } label: {
                        ImportedAppRow(app: app, iconData: viewModel.iconData[app.id])
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if pageMode == .installed {
                            Button("查看详情") { detailApp = app }
                        }
                        if pageMode == .unsigned {
                            Button("删除 IPA", role: .destructive) { pendingDeleteApp = app }
                        } else if app.isSeal == false, isExpired(app) {
                            Button("删除记录", role: .destructive) { pendingDeleteApp = app }
                        }
                    }

                    if index < apps.count - 1 {
                        Divider()
                            .padding(.leading, 84)
                            .padding(.trailing, 18)
                    }
                }
            }
            .sealListCard(cornerRadius: 20)
        }
    }

    private func emptyState(_ pageMode: ListMode) -> some View {
        VStack(spacing: 12) {
            Image(systemName: emptyIcon(for: pageMode))
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.sealAccent)
            Text(emptyTitle(for: pageMode))
                .font(.headline)
            if pageMode == .unsigned {
                Text("点击右上角 + 导入 IPA")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .sealListCard(cornerRadius: 20)
    }

    private func openApp(_ app: AppRecord, in pageMode: ListMode) {
        switch pageMode {
        case .unsigned:
            operationAppID = app.id
            viewModel.presentOperation(for: app)
        case .installed:
            installedActionApp = app
        }
    }

    private func operationSheetDismissed() {
        viewModel.dismissOperation()
        guard let operationAppID else { return }
        self.operationAppID = nil
        Task { @MainActor in
            await viewModel.load(force: true)
            if viewModel.installedApps.contains(where: { $0.id == operationAppID }) {
                withAnimation { mode = .installed }
            }
        }
    }

    private func resolveInitialModeIfNeeded() {
        guard didResolveInitialMode == false else { return }
        didResolveInitialMode = true
        if viewModel.unsignedApps.isEmpty && viewModel.installedApps.isEmpty {
            mode = .unsigned
        } else {
            mode = .installed
        }
    }

    private func refreshAppsPage(_ pageMode: ListMode) async {
        switch pageMode {
        case .unsigned:
            await viewModel.refreshUnsignedApps()
        case .installed:
            await viewModel.refreshInstalledApps()
        }
    }
    private func sectionTitle(for pageMode: ListMode) -> String {
        switch pageMode {
        case .unsigned: "待签名应用"
        case .installed: "已安装应用"
        }
    }

    private func emptyTitle(for pageMode: ListMode) -> String {
        switch pageMode {
        case .unsigned: "暂无待签名应用"
        case .installed: "暂无已安装应用"
        }
    }

    private func emptyIcon(for pageMode: ListMode) -> String {
        switch pageMode {
        case .unsigned: "square.and.arrow.down"
        case .installed: "app.badge.checkmark"
        }
    }

    private func operationDetents(for app: AppRecord) -> Set<PresentationDetent> {
        if app.belongsInInstalledList { return installedOperationDetents }
        let extraExtensionHeight = CGFloat(min(app.extensions.count, 4)) * 10
        return [.height(CGFloat(660) + extraExtensionHeight), .large]
    }

    private var installedOperationDetents: Set<PresentationDetent> {
        [.height(560), .large]
    }

    private var deleteAlertTitle: String {
        pendingDeleteApp?.belongsInInstalledList == true ? "删除记录？" : "删除 IPA？"
    }

    private var deleteAlertMessage: String {
        guard pendingDeleteApp?.belongsInInstalledList == true else {
            return "删除后将从 Seal 的待签名列表中移除，并删除 Seal 保存的导入 IPA，不会影响手机上已安装的应用。"
        }
        return "删除后将从 Seal 的已安装列表中移除，不会卸载手机上的应用。"
    }

    private var batchRefreshMenu: some View {
        Button {
            viewModel.refreshAll()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("续签全部")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.sealAccent)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.sealAccent.opacity(0.10), in: Capsule())
        }
        .accessibilityLabel("续签全部")
    }

    private func isExpired(_ app: AppRecord, now: Date = Date()) -> Bool {
        guard let expiryDate = app.expiryDate else { return false }
        return expiryDate <= now
    }

    private func standardAlert(_ failure: ImportFailure) -> Alert {
        Alert(
            title: Text(failure.title),
            message: Text(failure.userMessage),
            dismissButton: .default(Text(failure.recovery)) {
                viewModel.performAlertRecovery(for: failure)
            }
        )
    }

    private var rootAlertFailure: Binding<ImportFailure?> {
        Binding(
            get: {
                viewModel.selectedOperationApp == nil && installedActionApp == nil
                    ? viewModel.alertFailure
                    : nil
            },
            set: { viewModel.alertFailure = $0 }
        )
    }

    private func cancelDraftIfNeeded() {
        if viewModel.phase != .committing, viewModel.sheetDraft != nil {
            Task { await viewModel.cancelImport() }
        }
    }
}

private extension UTType {
    static let ipaArchive = UTType(filenameExtension: "ipa") ?? .data
    static let zipArchive = UTType(filenameExtension: "zip") ?? .archive
}

private struct SealListCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.sealSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.sealHairline.opacity(0.55), lineWidth: 0.8)
            }
    }
}

private extension View {
    func sealListCard(cornerRadius: CGFloat) -> some View {
        modifier(SealListCardModifier(cornerRadius: cornerRadius))
    }
}
