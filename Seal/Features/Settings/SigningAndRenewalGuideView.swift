import SwiftUI

struct SigningAndRenewalGuideView: View {
    @State private var expandedSection: SigningGuideSection? = .requirements

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SigningGuideSection.allCases) { section in
                    SigningGuideAccordionCard(
                        section: section,
                        isExpanded: expandedSection == section,
                        onTap: { toggle(section) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 34)
        }
        .navigationTitle("签名与续签")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground(.secondary)
    }

    private func toggle(_ section: SigningGuideSection) {
        withAnimation(.easeInOut(duration: 0.22)) {
            expandedSection = expandedSection == section ? nil : section
        }
    }
}

private enum SigningGuideSection: String, CaseIterable, Identifiable {
    case requirements
    case pairing
    case signingIPA
    case renewal
    case batchRenewal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requirements: return "准备条件"
        case .pairing: return "设备配对"
        case .signingIPA: return "签名 IPA"
        case .renewal: return "续签 App"
        case .batchRenewal: return "批量续签"
        }
    }

    var icon: String {
        switch self {
        case .requirements: return "checkmark.shield"
        case .pairing: return "cable.connector"
        case .signingIPA: return "app.badge"
        case .renewal: return "arrow.clockwise"
        case .batchRenewal: return "square.stack.3d.up"
        }
    }

    var steps: [String] {
        switch self {
        case .requirements:
            return [
                "确保连接 Wi-Fi",
                "开启 LocalDevVPN",
                "添加 Apple ID",
                "完成设备配对"
            ]
        case .pairing:
            return [
                "用数据线连接 iPhone 和电脑",
                "从电脑打开 Seal 配对助手",
                "按提示生成配对文件，并导入 Seal",
                "在 iPhone 上信任这台电脑",
                "在设备页刷新，确认配对成功"
            ]
        case .signingIPA:
            return [
                "导入 IPA",
                "点开待签名 App",
                "确认 App 名称、图标、Bundle ID 是否需要更改",
                "点击“签名并安装”"
            ]
        case .renewal:
            return [
                "打开已安装页",
                "点开需要续签的 App",
                "点击“立即续签”"
            ]
        case .batchRenewal:
            return [
                "打开已安装页",
                "点击“续签全部”",
                "Seal 会最后续签自身，并退出进行安装"
            ]
        }
    }
}

private struct SigningGuideAccordionCard: View {
    let section: SigningGuideSection
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                SigningGuideHeader(section: section, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                        .padding(.leading, 44)
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        SigningGuideStepRow(index: index, text: step)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(isExpanded ? Color.sealSurfaceElevated : Color.sealSurface)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(isExpanded ? Color.sealAccent.opacity(0.24) : Color.sealHairline.opacity(0.58), lineWidth: 0.8)
    }
}

private struct SigningGuideHeader: View {
    let section: SigningGuideSection
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 30, height: 30)
                .background(Color.sealAccent.opacity(isExpanded ? 0.16 : 0.10), in: Circle())

            Text(section.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.sealTextSecondary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

private struct SigningGuideStepRow: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 24, height: 24)
                .background(Color.sealAccent.opacity(0.12), in: Circle())

            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
