import SwiftUI
import UIKit

struct InstalledAppActionSheet: View {
    let app: AppRecord
    @ObservedObject var viewModel: AppsViewModel
    let onRenew: () -> Void
    let onShowDetail: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SealDrawer(title: "应用操作") {
            VStack(alignment: .leading, spacing: 16) {
                appHeader
                signingSummaryCard
            }
            .padding(.bottom, 12)
        } footer: {
            VStack(spacing: 10) {
                Button("立即续签") {
                    dismiss()
                    onRenew()
                }
                .sealPrimaryAction(cornerRadius: 14)


            }
        }
    }

    private var appHeader: some View {
        HStack(spacing: 14) {
            icon(size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("v\(app.version) · \(app.size.sealFormattedByteCount)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var signingSummaryCard: some View {
        VStack(spacing: 0) {
            metadataRow("签名账户", accountSummary)
            Divider().padding(.leading, 14)
            metadataRow("Apple ID 证书", certificateSummary)
            Divider().padding(.leading, 14)
            metadataRow("描述文件", profileStatus.title, valueColor: profileStatusColor)
            Divider().padding(.leading, 14)
            metadataRow("有效期至", expirySummary, valueColor: expiryColor)
            Divider().padding(.leading, 14)
            metadataRow("Bundle ID", bundleIDSummary, usesMiddleTruncation: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .glassSurface(cornerRadius: 18)
    }

    private func metadataRow(
        _ title: String,
        _ value: String,
        valueColor: Color = Color.sealTextSecondary,
        usesMiddleTruncation: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(usesMiddleTruncation ? .middle : .tail)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        Group {
            if let data = viewModel.iconData[app.id], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .foregroundStyle(Color.sealAccent)
                    .background(Color.sealSurfaceElevated)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    private var accountSummary: String {
        guard let account = viewModel.accounts.first(where: { $0.id == app.accountID }) else {
            return "未记录"
        }
        return viewModel.fullEmail(for: account)
    }

    private var certificateSummary: String {
        if let serial = app.certificateSerialNumber, serial.isEmpty == false {
            return "可用"
        }
        if app.signingTargets
            .flatMap(\.certificateSerialNumbers)
            .contains(where: { $0.isEmpty == false }) {
            return "可用"
        }
        return "未准备"
    }

    private var bundleIDSummary: String {
        app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier
    }

    private var profileStatus: ProfileDisplayStatus {
        AppSigningPresentationHelpers.profileStatus(for: app)
    }

    private var profileStatusColor: Color {
        switch profileStatus.tone {
        case .danger:
            Color.sealDanger
        case .success, .warning, .neutral:
            Color.sealTextSecondary
        }
    }

    private var expirySummary: String {
        guard let date = AppSigningPresentationHelpers.profileExpirationDate(for: app) else { return "未记录" }
        return SealSettingsDateFormatter.string(from: date)
    }

    private var expiryColor: Color {
        color(for: profileStatus.tone)
    }

    private func color(for tone: AppValidityTone) -> Color {
        switch tone {
        case .success: .sealSuccess
        case .warning: .sealWarning
        case .danger: .sealDanger
        case .neutral: .sealTextSecondary
        }
    }
}
