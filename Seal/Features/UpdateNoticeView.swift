import SwiftUI

/// 更新通知弹窗（iOS 系统风格，紧凑布局）
struct UpdateNoticeView: View {
    let notice: UpdateNotice
    let onDismiss: () -> Void
    @State private var wechatCopied = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 0) {
                // 顶部：图标 + 标题 + 版本号（紧凑排列）
                HStack(spacing: 12) {
                    Image(uiImage: UIImage(named: "AppIcon") ?? UIImage())
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("新版本 \(notice.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                // 更新列表（左对齐，更易读）
                VStack(alignment: .leading, spacing: 8) {
                    Text(notice.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // 公众号引流（一行）
                Text("公众号「MJorb」回复「更新」下载")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 16)

                // 按钮区
                VStack(spacing: 10) {
                    Button(action: {
                        UIPasteboard.general.string = "MJorb"
                        wechatCopied = true
                        if let url = URL(string: "weixin://") {
                            UIApplication.shared.open(url)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            wechatCopied = false
                        }
                    }) {
                        Text(wechatCopied ? "已复制，去微信搜索" : "复制名称并打开微信")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.sealAccent)
                            )
                    }
                    Button(action: onDismiss) {
                        Text("忽略此版本")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 12)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}
